#!/usr/bin/env python3
"""JPEG 세그먼트 수술 도구 — 카메라가 만든 파일의 구조에 맞춘다.

Kodak PIXPRO FZ55 가 실제로 쓰는 세그먼트 구성:  APP1(Exif) [APP5 APP6] DQT SOF0 DHT SOS
cjpeg / ffmpeg 이 만드는 JPEG 에는 APP0(JFIF)·COM 이 붙고 DQT/DHT 가 여러 세그먼트로 나뉜다.
ffmpeg 은 색차 성분이 양자화 테이블 0 을 보도록 적는다.

- APP0(JFIF) / APP2(ICC) / COM 은 카메라 파일에 없으므로 지우고, 세그먼트를 카메라 순서로 재배열한다.
- --merge-tables     : 나뉜 DQT/DHT 를 각각 하나로 합친다.
- --chroma-qtable N  : SOF0 의 색차 성분이 볼 양자화 테이블 번호를 N 으로 바꾼다.
- --stream           : 이어붙은 raw MJPEG 스트림을 프레임 단위로 처리한다(동영상용).
- --appn-from REF    : 참조 파일의 APP5/APP6 을 APP1 뒤에 그대로 삽입한다.
"""
import argparse
import mmap
import sys

SOI, EOI, SOS = 0xD8, 0xD9, 0xDA
DROP = {0xE0, 0xE2, 0xFE}          # APP0(JFIF), APP2(ICC), COM
COPY = (0xE5, 0xE6)                # APP5, APP6 (코닥 독자 영역)


def parse(data):
    """(marker, start_offset, end_offset) 목록. SOS 이후는 통째로 tail 취급."""
    if data[:2] != b"\xff\xd8":
        raise ValueError("JPEG(SOI) 이 아닙니다")
    out, i = [], 2
    while i < len(data) - 1:
        if data[i] != 0xFF:
            raise ValueError(f"오프셋 {i}: 세그먼트 마커가 아닙니다")
        m = data[i + 1]
        if m == SOS:
            out.append((m, i, len(data)))     # SOS + 압축데이터 + EOI
            break
        if m == EOI:
            out.append((m, i, i + 2))
            break
        ln = int.from_bytes(data[i + 2:i + 4], "big")
        out.append((m, i, i + 2 + ln))
        i += 2 + ln
    return out


def merge(chunks, marker):
    """같은 종류의 세그먼트 여러 개를 payload 만 이어붙여 하나로 만든다."""
    body = b"".join(c[4:] for c in chunks)      # 각 chunk = FF xx len(2) payload
    return bytes([0xFF, marker]) + (len(body) + 2).to_bytes(2, "big") + body


def extract(path, markers):
    data = open(path, "rb").read()
    found = {}
    for m, s, e in parse(data):
        if m in markers and m not in found:
            found[m] = data[s:e]
    return found


def rebuild(data, extra=b"", merge_tables=False, chroma_q=None):
    """JPEG 한 장을 카메라 구조로 재구성해 돌려준다."""
    apps, dqt, sof, dht, tail, dropped = [], [], [], [], b"", []
    for m, s_, e in parse(data):
        chunk = data[s_:e]
        if m in DROP:
            dropped.append(f"APP{m - 0xE0}" if 0xE0 <= m <= 0xEF else "COM")
        elif m == SOS:
            tail = chunk
        elif m == 0xDB:
            dqt.append(chunk)
        elif m == 0xC4:
            dht.append(chunk)
        elif 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            sof.append(patch_sof(chunk, chroma_q) if chroma_q is not None else chunk)
        elif 0xE0 <= m <= 0xEF:
            apps.append(chunk)
        else:
            dht.append(chunk)

    if merge_tables:
        if len(dqt) > 1:
            dqt = [merge(dqt, 0xDB)]
        if len(dht) > 1:
            dht = [merge(dht, 0xC4)]

    out = bytearray(b"\xff\xd8")
    out += b"".join(apps) + extra
    out += b"".join(dqt) + b"".join(sof) + b"".join(dht) + tail
    return bytes(out), dropped


def patch_sof(chunk, tq):
    """SOF0 의 2·3번 성분이 참조하는 양자화 테이블 번호를 바꾼다(크기 불변)."""
    b = bytearray(chunk)
    nc = b[9]                      # FF C0 len(2) prec h(2) w(2) nc
    for k in range(1, nc):         # 0번(휘도)은 그대로 두고 색차만
        b[10 + 3 * k + 2] = tq
    return bytes(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--appn-from", metavar="REF",
                    help="이 카메라 파일의 APP5/APP6 을 복사해 넣는다")
    ap.add_argument("--merge-tables", action="store_true",
                    help="흩어진 DQT/DHT 세그먼트를 각각 하나로 합친다 "
                         "(cjpeg 은 DQT 2개·DHT 4개로 나눠 쓰지만 카메라는 각각 1개로 쓴다)")
    ap.add_argument("--chroma-qtable", type=int, metavar="N",
                    help="SOF0 의 색차 성분(2,3)이 참조할 양자화 테이블 번호. "
                         "카메라는 1 을 쓰지만 ffmpeg 은 0 으로 적는다")
    ap.add_argument("--stream", action="store_true",
                    help="파일 하나에 JPEG 이 연속으로 이어붙은 raw MJPEG 스트림을 처리한다")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    data = b"" if a.stream else open(a.src, "rb").read()

    extra = b""
    if a.appn_from:
        got = extract(a.appn_from, COPY)
        extra = b"".join(got[m] for m in COPY if m in got)
        if not a.quiet:
            for m in COPY:
                print(f"  APP{m - 0xE0} 복사: {len(got[m])} bytes" if m in got
                      else f"  APP{m - 0xE0} 없음 — 건너뜀", file=sys.stderr if m not in got else sys.stdout)

    if a.stream:
        # 동영상은 수 GB 가 될 수 있으므로 전체를 메모리에 올리지 않는다.
        # mmap 으로 훑으면서 프레임 하나씩 변환해 바로 써 나간다.
        n = written = 0
        with open(a.src, "rb") as fi, open(a.dst, "wb") as fo:
            mm = mmap.mmap(fi.fileno(), 0, access=mmap.ACCESS_READ)
            try:
                i = 0
                while True:
                    s_ = mm.find(b"\xff\xd8\xff", i)
                    if s_ < 0:
                        break
                    e = mm.find(b"\xff\xd9", s_ + 2)
                    if e < 0:
                        break
                    e += 2
                    frame, _ = rebuild(mm[s_:e], extra, a.merge_tables, a.chroma_qtable)
                    fo.write(frame)
                    written += len(frame)
                    n += 1
                    i = e
                size = mm.size()
            finally:
                mm.close()
        if n == 0:
            sys.exit("오류: MJPEG 스트림에서 JPEG 프레임을 찾지 못했습니다")
        if not a.quiet:
            print(f"  프레임 {n}장 처리   {size:,}B -> {written:,}B")
        return

    out, dropped = rebuild(data, extra, a.merge_tables, a.chroma_qtable)
    open(a.dst, "wb").write(out)
    if not a.quiet:
        print(f"  제거: {', '.join(dropped) if dropped else '없음'}"
              f"   {len(data):,}B -> {len(out):,}B")


if __name__ == "__main__":
    main()
