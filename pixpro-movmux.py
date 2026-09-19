#!/usr/bin/env python3
"""pixpro-movmux.py — Kodak PIXPRO FZ55 가 녹화한 것과 동일한 레이아웃의 MOV 를 직접 조립한다.

ffmpeg 의 mov 먹서로 만든 파일은 카메라에서 영상만 빨리감기로 재생된다(소리는 정상).
컨테이너 구조가 카메라 것과 달라서다. 실기 원본(FW 1.06) 분석 결과:

  최상위:   wide  mdat  moov  free          (ftyp 없음)
  mdat:     [영상 15프레임][오디오 22048B(0.5초)] 반복. 프레임은 16바이트 배수로 패딩
  moov:     edts/elst 없음, tkhd flags=0xf, hdlr vendor='KODA',
            오디오 stsd 는 버전 1, mvhd/비디오 mdhd 타임스케일 3000 (프레임당 100)

어느 필드가 펌웨어를 오작동시키는지 추측하는 대신, 카메라 원본의 moov 를 템플릿으로
읽어 원자(atom) 바이트를 그대로 재사용하고 길이/크기/오프셋 같은 숫자만 교체한다.

입력:
  --template  카메라가 1920x1080/30fps 모드로 직접 녹화한 MOV. ffmpeg 으로 재먹싱한 적 없는
              원본이어야 한다. 이 모드의 타임스케일(3000)을 가정하며 템플릿 값은 검사하지 않는다.
  --video     raw MJPEG 스트림 (pixpro-jpegfix.py --stream 으로 교정된 것)
  --audio     raw mu-law, 44100Hz, 모노 (없으면 무음으로 채운다)
"""
import argparse
import calendar
import mmap
import os
import struct
import sys
import time

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}
AUDIO_CHUNK = 22048          # 카메라의 오디오 청크 크기 (mu-law 1바이트/샘플 ≈ 0.5초)
AUDIO_RATE = 44100
MOVIE_TS = 3000              # mvhd / 비디오 mdhd 타임스케일
ALIGN = 16                   # 카메라는 모든 프레임을 16바이트 배수로 맞춘다
ULAW_SILENCE = 0xFF
QT_EPOCH = 2082844800        # 1904-01-01 ~ 1970-01-01 (초)


def parse_atoms(buf, start, end):
    out, i = [], start
    while i + 8 <= end:
        size = struct.unpack(">I", buf[i:i + 4])[0]
        typ = bytes(buf[i + 4:i + 8])
        if size < 8 or i + size > end:
            raise ValueError(f"깨진 atom {typ!r} @ {i}")
        if typ in CONTAINERS:
            out.append([typ, parse_atoms(buf, i + 8, i + size)])
        else:
            out.append([typ, bytearray(buf[i + 8:i + size])])
        i += size
    return out


def serialize(atoms):
    out = bytearray()
    for typ, val in atoms:
        body = serialize(val) if isinstance(val, list) else bytes(val)
        out += struct.pack(">I", len(body) + 8) + typ + body
    return bytes(out)


def child(atoms, typ):
    for a in atoms:
        if a[0] == typ:
            return a
    raise KeyError(typ)


def put32(payload, off, value):
    payload[off:off + 4] = struct.pack(">I", value)


def full_table(entries, fmt):
    """ver/flags(0) + 항목수 + 항목들"""
    body = bytearray(struct.pack(">II", 0, len(entries)))
    for e in entries:
        body += struct.pack(fmt, *e) if isinstance(e, tuple) else struct.pack(fmt, e)
    return body


def iter_frames(path):
    """raw MJPEG 스트림에서 JPEG 프레임 바이트를 하나씩 돌려준다."""
    with open(path, "rb") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            i = 0
            while True:
                s = mm.find(b"\xff\xd8\xff", i)
                if s < 0:
                    break
                e = mm.find(b"\xff\xd9", s + 2)
                if e < 0:
                    break
                e += 2
                yield mm[s:e]
                i = e
        finally:
            mm.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--template", required=True)
    ap.add_argument("--video", required=True)
    ap.add_argument("--audio")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--date", metavar="'YYYY:MM:DD HH:MM:SS'",
                    help="촬영일시. 카메라처럼 로컬 시각을 변환 없이 그대로 기록한다. "
                         "생략하면 템플릿의 날짜가 남는다")
    a = ap.parse_args()

    qt_time = None
    if a.date:
        try:
            qt_time = calendar.timegm(time.strptime(a.date, "%Y:%m:%d %H:%M:%S")) + QT_EPOCH
        except ValueError:
            sys.exit(f"오류: --date 형식이 잘못됐습니다: {a.date!r}")

    if MOVIE_TS % a.fps:
        sys.exit(f"오류: fps={a.fps} 는 타임스케일 {MOVIE_TS} 의 약수가 아닙니다 (30 또는 60)")
    delta = MOVIE_TS // a.fps
    frames_per_chunk = max(1, a.fps // 2)          # 0.5초 분량

    # ---- 템플릿 moov 읽기 -------------------------------------------------
    tpl = open(a.template, "rb").read()
    top, i = [], 0
    while i + 8 <= len(tpl):
        size = struct.unpack(">I", tpl[i:i + 4])[0]
        if size < 8:
            break
        top.append((bytes(tpl[i + 4:i + 8]), i, size))
        i += size
    names = [t for t, _, _ in top]
    if b"ftyp" in names or b"moov" not in names:
        sys.exit("오류: 템플릿이 카메라 원본이 아닙니다 (ffmpeg 재먹싱본에는 ftyp 가 생긴다)")
    _, mo, msz = next(x for x in top if x[0] == b"moov")
    moov = parse_atoms(tpl, mo + 8, mo + msz)
    tail = b"".join(tpl[o:o + s] for t, o, s in top if o > mo)      # 끝의 free atom

    # ---- 프레임 수 / 오디오 준비 ------------------------------------------
    n_frames = sum(1 for _ in iter_frames(a.video))
    if n_frames == 0:
        sys.exit("오류: MJPEG 스트림에 프레임이 없습니다")
    n_samples = n_frames * AUDIO_RATE // a.fps
    audio = b""
    if a.audio and os.path.exists(a.audio):
        audio = open(a.audio, "rb").read()[:n_samples]
    audio += bytes([ULAW_SILENCE]) * (n_samples - len(audio))       # 짧으면 무음으로 채움
    n_achunks = -(-n_samples // AUDIO_CHUNK)

    # ---- mdat 쓰기: [영상 15프레임][오디오 1청크] 반복 ---------------------
    v_sizes, v_offs, a_offs = [], [], []
    with open(a.out, "wb") as fo:
        fo.write(struct.pack(">I", 8) + b"wide")
        fo.write(struct.pack(">I", 0) + b"mdat")                    # 크기는 나중에 채움
        frames = iter_frames(a.video)
        vi = 0
        for k in range(n_achunks):
            upto = n_frames if k == n_achunks - 1 else min(n_frames, (k + 1) * frames_per_chunk)
            while vi < upto:
                fr = next(frames)
                pad = (-len(fr)) % ALIGN
                v_offs.append(fo.tell())
                v_sizes.append(len(fr) + pad)
                fo.write(fr)
                fo.write(b"\x00" * pad)
                vi += 1
            a_offs.append(fo.tell())
            fo.write(audio[k * AUDIO_CHUNK:(k + 1) * AUDIO_CHUNK])
        mdat_end = fo.tell()
        mdat_size = mdat_end - 8
        if mdat_size >= 2 ** 32:
            sys.exit("오류: 4GB 를 넘습니다. 영상을 나누거나 --size 를 줄이세요")

        # ---- moov 숫자 교체 ------------------------------------------------
        duration = n_frames * delta
        put32(child(moov, b"mvhd")[1], 16, duration)

        def stamp(payload):                 # ver/flags(4) 생성(4) 수정(4)
            if qt_time is not None:
                put32(payload, 4, qt_time)
                put32(payload, 8, qt_time)
        stamp(child(moov, b"mvhd")[1])

        for trak in (x for x in moov if x[0] == b"trak"):
            tk = child(trak[1], b"tkhd")[1]
            mdia = child(trak[1], b"mdia")[1]
            kind = bytes(child(mdia, b"hdlr")[1][8:12])
            stbl = child(child(mdia, b"minf")[1], b"stbl")[1]
            put32(tk, 20, duration)
            stamp(tk)
            stamp(child(mdia, b"mdhd")[1])
            if kind == b"vide":
                put32(tk, 76, a.width << 16)
                put32(tk, 80, a.height << 16)
                put32(child(mdia, b"mdhd")[1], 16, duration)
                sd = child(stbl, b"stsd")[1]
                sd[40:44] = struct.pack(">HH", a.width, a.height)
                child(stbl, b"stts")[1][:] = full_table([(n_frames, delta)], ">II")
                child(stbl, b"stsc")[1][:] = full_table([(1, 1, 1)], ">III")
                child(stbl, b"stsz")[1][:] = struct.pack(">III", 0, 0, n_frames) + \
                    b"".join(struct.pack(">I", s) for s in v_sizes)
                child(stbl, b"stco")[1][:] = full_table(v_offs, ">I")
            elif kind == b"soun":
                put32(child(mdia, b"mdhd")[1], 16, n_samples)
                child(stbl, b"stts")[1][:] = full_table([(n_samples, 1)], ">II")
                rem = n_samples % AUDIO_CHUNK
                sc = [(1, min(AUDIO_CHUNK, n_samples), 1)]
                if rem and n_achunks > 1:
                    sc.append((n_achunks, rem, 1))
                child(stbl, b"stsc")[1][:] = full_table(sc, ">III")
                child(stbl, b"stsz")[1][:] = struct.pack(">III", 0, 1, n_samples)
                child(stbl, b"stco")[1][:] = full_table(a_offs, ">I")

        fo.write(struct.pack(">I", 0) + b"moov")
        moov_pos = fo.tell() - 8
        fo.write(serialize(moov))
        moov_end = fo.tell()
        fo.write(tail)
        fo.seek(moov_pos); fo.write(struct.pack(">I", moov_end - moov_pos))
        fo.seek(8);        fo.write(struct.pack(">I", mdat_size))

    print(f"  프레임 {n_frames}장 / 오디오 {n_samples}샘플({n_achunks}청크) / "
          f"{duration / MOVIE_TS:.2f}초 / {os.path.getsize(a.out):,}B")


if __name__ == "__main__":
    main()
