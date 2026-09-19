#!/usr/bin/env bash
# pixpro-convert.sh — Kodak PIXPRO FZ55 용 사진/영상 변환기 (비공식)
#
# 카드 구조 (FZ55, 펌웨어 1.06 에서 확인):
#   DCIM/100KFZ55/100_0120.JPG   사진 또는 동영상(.MOV)
#   SCN/100KFZ55/100_0120.THM    프리뷰. 카메라는 재생 화면을 이 THM 에서 그리므로 반드시 함께 만든다.
# 사진: baseline JPEG, 4:2:2 (샘플링 2x1/1x1/1x1, 색차는 양자화 테이블 1), 표준 허프만 테이블.
#       EXIF 는 참조 사진에서 복제한다.
# 영상: MOV / MJPEG 4:2:0 + mu-law 44100Hz 모노 (매뉴얼의 "Linear PCM" 표기는 틀리다).
#       컨테이너는 pixpro-movmux.py 가 참조 MOV 의 moov 를 템플릿으로 직접 조립한다.
# 자세한 내용: README.md, docs/TECHNICAL.md
#
# 사용법:
#   ./pixpro-convert.sh photo   --ref <참조JPG> --out <폴더> [--start N] [--size WxH] [--prefix S] [--appn] <사진...>
#   ./pixpro-convert.sh video   --ref <참조MOV> --out <폴더> [--start N] [--size WxH] [--fps 30] [--date 'YYYY:MM:DD HH:MM:SS'] <영상...>
#   ./pixpro-convert.sh deploy  <out폴더> <카드경로>   예: deploy out "/Volumes/NO NAME"  (끝에 / 를 붙이지 말 것)
#   ./pixpro-convert.sh clean   <카드경로>             macOS 숨김 파일만 제거
#   ./pixpro-convert.sh inspect <파일...>              구조·메타데이터 출력
#
# 참조 파일은 카드와 같은 구조·파일명 그대로 둔다. --start 는 카드의 마지막 번호 + 1 로 직접 지정할 것.

set -euo pipefail

die() { printf '오류: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 이(가) 필요합니다.  brew install $2"; }

need ffmpeg ffmpeg
need ffprobe ffmpeg
need exiftool exiftool
need cjpeg jpeg-turbo

# ---------------------------------------------------------------- inspect
cmd_inspect() {
  [ $# -gt 0 ] || die "분석할 파일을 지정하세요."
  for f in "$@"; do
    [ -f "$f" ] || die "파일 없음: $f"
    printf '\n══════ %s ══════\n폴더: %s\n이름: %s\n' "$f" "$(dirname "$f")" "$(basename "$f")"
    ffprobe -hide_banner -v error \
      -show_entries stream=codec_name,codec_type,profile,width,height,r_frame_rate,pix_fmt,sample_rate,channels \
      -show_entries format=format_name,duration,bit_rate -of default=noprint_wrappers=1 "$f" 2>/dev/null || true
    exiftool -a -G1 -s "$f" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------- 인자 파싱
# 정지화상 인코딩은 ffmpeg 이 아니라 cjpeg(libjpeg) 으로 한다.
# ffmpeg 의 mjpeg 인코더는 4:2:2 를 샘플링 팩터 2x2/1x2/1x2 로 적고 색차 양자화
# 테이블을 분리하지 않는다(세 성분 모두 q0). 카메라의 하드웨어 디코더는 이를 받지
# 못해 재생 시 "?" 로 표시한다. cjpeg 은 카메라와 동일한 정규 구조를 만든다:
#   id1:2x1->q0  id2:1x1->q1  id3:1x1->q1
TMPD=""
enc_jpeg() {   # <src> <vf필터> <품질> <출력경로>
  ffmpeg -hide_banner -loglevel error -y -i "$1" -vf "$2" -frames:v 1 -pix_fmt rgb24 "$TMPD/enc.ppm"
  cjpeg -quality "$3" -sample 2x1 -dct int -outfile "$4" "$TMPD/enc.ppm"
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JPEGFIX="$HERE/pixpro-jpegfix.py"
MOVMUX="$HERE/pixpro-movmux.py"

REF=""; OUT=""; START=""; PREFIX=""; SIZE=""; FPS=""; APPN=""; DATE=""
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) REF="$2"; shift 2 ;;  --out) OUT="$2"; shift 2 ;;
      --start) START="$2"; shift 2 ;;  --prefix) PREFIX="$2"; shift 2 ;;
      --size) SIZE="$2"; shift 2 ;;  --fps) FPS="$2"; shift 2 ;;
      --appn) APPN=1; shift ;;
      --date) DATE="$2"; shift 2 ;;
      --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
      -*) die "알 수 없는 옵션: $1" ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done
}

# 참조 파일명에서 접두사와 다음 번호를 뽑는다. 100_0348.JPG -> 접두사 "100_", 다음 349
derive_naming() {
  local stem; stem="$(basename "$REF")"; stem="${stem%.*}"
  [[ "$stem" =~ ^(.{4})([0-9]{4})$ ]] \
    || die "참조 파일명 '$stem' 이(가) DCF 형식(4자+숫자4)이 아닙니다. --prefix/--start 를 직접 지정하세요."
  [ -n "$PREFIX" ] || PREFIX="${BASH_REMATCH[1]}"
  [ -n "$START" ]  || START=$((10#${BASH_REMATCH[2]} + 1))
  printf '명명 규칙: 접두사="%s", 시작번호=%04d\n' "$PREFIX" "$START" >&2
}

# 동영상 원본의 촬영일시. QuickTime 날짜는 UTC 로 저장되므로 로컬 시각으로 환산해 읽는다.
# 날짜가 없는 파일(0000:00:00)은 파일 수정시각으로 대체한다.
video_date() {
  local d
  d="$(exiftool -m -s3 -api QuickTimeUTC=1 -d '%Y:%m:%d %H:%M:%S' -CreateDate "$1" 2>/dev/null | head -1)"
  case "$d" in ""|0000*) d="$(exiftool -m -s3 -d '%Y:%m:%d %H:%M:%S' -FileModifyDate "$1" | head -1)" ;; esac
  printf '%s' "$d"
}

# 원본의 촬영일시(없으면 파일 수정시각)
shot_date() {
  exiftool -s3 -d '%Y:%m:%d %H:%M:%S' -DateTimeOriginal -CreateDate -FileModifyDate "$1" 2>/dev/null | head -1
}

# ---------------------------------------------------------------- photo
cmd_photo() {
  parse_opts "$@"
  [ -n "$REF" ] || die "--ref <카드의 카메라 JPG> 가 필요합니다. (EXIF/MakerNotes 를 그대로 복제합니다)"
  [ -f "$REF" ] || die "참조 파일 없음: $REF"
  [ -n "$OUT" ] || die "--out <폴더> 가 필요합니다."
  [ ${#ARGS[@]} -gt 0 ] || die "변환할 사진을 지정하세요."
  derive_naming

  # SCN 쪽 참조 THM 을 경로 규칙으로 찾는다: .../DCIM/<폴더>/X.JPG -> .../SCN/<폴더>/X.THM
  local folder card thmref
  folder="$(basename "$(dirname "$REF")")"                 # 100KFZ55
  card="$(dirname "$(dirname "$(dirname "$REF")")")"       # /Volumes/NO NAME
  thmref="$card/SCN/$folder/$(basename "${REF%.*}").THM"
  if [ -f "$thmref" ]; then
    printf 'THM 참조: %s\n' "$thmref" >&2
  else
    thmref=""
    printf '경고: 대응하는 THM 을 찾지 못했습니다(%s). THM 없이 진행합니다.\n' "$card/SCN/$folder/" >&2
  fi

  # 기본 해상도는 참조 이미지와 동일하게
  if [ -z "$SIZE" ]; then
    SIZE="$(exiftool -s3 -ImageWidth -ImageHeight "$REF" | paste -sd'x' -)"
  fi
  local W="${SIZE%x*}" H="${SIZE#*x}"
  printf '출력 해상도: %sx%s (카메라 파일과 동일 규격: baseline JPEG / YCbCr 4:2:2)\n\n' "$W" "$H" >&2

  mkdir -p "$OUT/DCIM/$folder"
  [ -n "$thmref" ] && mkdir -p "$OUT/SCN/$folder"

  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  TMPD="$tmp"
  local n="$START"

  for src in "${ARGS[@]}"; do
    [ -f "$src" ] || die "파일 없음: $src"
    local stem; stem="$(printf '%s%04d' "$PREFIX" "$n")"
    local jpg="$OUT/DCIM/$folder/$stem.JPG"
    local shot; shot="$(shot_date "$src")"
    local fit="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:black"

    # 본 이미지 / 임베디드 썸네일(160x120) / THM 본체(640x480) — 전부 4:2:2 baseline
    enc_jpeg "$src"          "$fit"            92 "$tmp/full.jpg"
    enc_jpeg "$tmp/full.jpg" "scale=160:120"   85 "$tmp/thumb.jpg"
    enc_jpeg "$tmp/full.jpg" "scale=640:480"   92 "$tmp/thm.jpg"

    # 본 이미지: 카메라 파일의 EXIF 를 MakerNotes 까지 통째로 복제한 뒤 크기/날짜/썸네일만 교정
    cp "$tmp/full.jpg" "$jpg"
    exiftool -m -q -q -overwrite_original -tagsFromFile "$REF" -all:all -unsafe "$jpg"
    exiftool -m -q -q -overwrite_original -ExifByteOrder=MM \
      -EXIF:Orientation#=1 \
      -EXIF:ExifImageWidth#="$W" -EXIF:ExifImageHeight#="$H" \
      -EXIF:DateTimeOriginal="$shot" -EXIF:CreateDate="$shot" -EXIF:ModifyDate="$shot" \
      "-ThumbnailImage<=$tmp/thumb.jpg" "$jpg"

    # cjpeg 이 붙이는 APP0(JFIF) 처럼 카메라 파일에 없는 세그먼트를 지우고,
    # 여러 개로 나뉜 DQT/DHT 를 하나씩으로 합쳐 카메라와 같은 순서로 맞춘다.
    # --appn 지정 시 카메라의 APP5/APP6(코닥 독자 영역)까지 그대로 복제한다.
    local fixargs=("$jpg" "$tmp/fixed.jpg" --quiet --merge-tables)
    [ -n "$APPN" ] && fixargs+=(--appn-from "$REF")
    python3 "$JPEGFIX" "${fixargs[@]}" && mv "$tmp/fixed.jpg" "$jpg"

    printf '  %-34s -> DCIM/%s/%s.JPG  (%s, %s)\n' "$(basename "$src")" "$folder" "$stem" \
      "$(exiftool -s3 -ImageSize "$jpg")" "$(du -h "$jpg" | cut -f1 | tr -d ' ')"

    # THM: 참조 THM 의 EXIF 를 그대로 복제 (본 이미지 크기 태그를 유지하는 것이 카메라 원본과 동일)
    if [ -n "$thmref" ]; then
      local thm="$OUT/SCN/$folder/$stem.THM"
      cp "$tmp/thm.jpg" "$thm"
      exiftool -m -q -q -overwrite_original -tagsFromFile "$thmref" -all:all -unsafe "$thm"
      exiftool -m -q -q -overwrite_original -ExifByteOrder=MM \
        -EXIF:Orientation#=1 \
        -EXIF:ExifImageWidth#="$W" -EXIF:ExifImageHeight#="$H" \
        -EXIF:DateTimeOriginal="$shot" -EXIF:CreateDate="$shot" -EXIF:ModifyDate="$shot" \
        "-ThumbnailImage<=$tmp/thumb.jpg" "$thm"
      local thmfix=("$thm" "$tmp/fixedthm.jpg" --quiet --merge-tables)
      [ -n "$APPN" ] && thmfix+=(--appn-from "$thmref")
      python3 "$JPEGFIX" "${thmfix[@]}" && mv "$tmp/fixedthm.jpg" "$thm"
      printf '  %-34s -> SCN/%s/%s.THM   (640x480, %s)\n' "" "$folder" "$stem" \
        "$(du -h "$thm" | cut -f1 | tr -d ' ')"
    fi

    n=$((n + 1))
  done
}

# ---------------------------------------------------------------- video
# 카메라 녹화본 규격 (FZ55 1920x1080/30fps 녹화본 분석, FW 1.06):
#   MJPEG 1920x1080 30fps yuvj420p + 오디오 mu-law 44100Hz 모노
#   프레임: DQT SOF0 DHT SOS (APP0/COM 없음), DQT=132 DHT=418, 2x2->q0 1x1->q1 1x1->q1
#   컨테이너: wide mdat moov free (ftyp·edts 없음), mvhd/비디오 mdhd 타임스케일 3000,
#             mdat 는 [영상 15프레임][오디오 22048B] 반복, 프레임은 16바이트 정렬
#
# ffmpeg 의 mov 먹서로 만들면 카메라에서 "영상만 빨리감기, 소리는 정상" 으로 재생된다.
# 그래서 ffmpeg 은 프레임 인코딩과 오디오 추출에만 쓰고, 컨테이너는 카메라 원본의
# moov 를 템플릿으로 pixpro-movmux.py 가 직접 조립한다.
#
# --ref 는 반드시 카메라가 1920x1080/30fps 모드로 직접 녹화한 원본이어야 한다. 먹서는 이 모드의
# 타임스케일(3000)을 가정한다. ffmpeg 으로 자르거나 복사한 파일은 컨테이너가 ffmpeg 것으로
# 바뀌어 템플릿으로 쓸 수 없다(먹서가 ftyp 로 걸러낸다). 작은 영상은 --size 로 만든다.
cmd_video() {
  parse_opts "$@"
  [ -n "$REF" ] || die "--ref <카메라가 녹화한 원본 MOV> 가 필요합니다."
  [ -f "$REF" ] || die "참조 파일 없음: $REF"
  [ -n "$OUT" ] || die "--out <폴더> 가 필요합니다."
  [ ${#ARGS[@]} -gt 0 ] || die "변환할 영상을 지정하세요."
  derive_naming

  local folder; folder="$(basename "$(dirname "$REF")")"
  local rw rh
  rw="$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$REF")"
  rh="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$REF")"
  [ -n "$SIZE" ] || SIZE="${rw}x${rh}"
  [ -n "$FPS" ]  || FPS=30
  local W="${SIZE%x*}" H="${SIZE#*x}"
  printf '출력 규격: %sx%s @%sfps, 오디오 44100Hz mono mu-law, 컨테이너는 카메라 원본 템플릿\n\n' "$W" "$H" "$FPS" >&2

  mkdir -p "$OUT/DCIM/$folder" "$OUT/SCN/$folder"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  TMPD="$tmp"
  local n="$START"

  for src in "${ARGS[@]}"; do
    [ -f "$src" ] || die "파일 없음: $src"
    local stem; stem="$(printf '%s%04d' "$PREFIX" "$n")"
    local dst="$OUT/DCIM/$folder/$stem.MOV"
    local thm="$OUT/SCN/$folder/$stem.THM"
    local fit="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:black"

    # 1) raw MJPEG 로 인코딩
    ffmpeg -hide_banner -loglevel error -y -i "$src" -vf "$fit" -r "$FPS" \
      -c:v mjpeg -pix_fmt yuvj420p -q:v 3 -huffman default -force_duplicated_matrix 1 \
      -f mjpeg "$tmp/raw.mjpeg"

    # 2) 프레임 수술: APP0/COM 제거, DQT SOF0 DHT 순서, 색차를 양자화 테이블 1 로
    python3 "$JPEGFIX" "$tmp/raw.mjpeg" "$tmp/fixed.mjpeg" \
      --stream --merge-tables --chroma-qtable 1 --quiet

    # 3) 오디오를 raw mu-law 로 추출 (없으면 먹서가 무음으로 채운다)
    rm -f "$tmp/audio.ulaw"
    if ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$src" 2>/dev/null | grep -q .; then
      ffmpeg -hide_banner -loglevel error -y -i "$src" -vn -ac 1 -ar 44100 \
        -c:a pcm_mulaw -f mulaw "$tmp/audio.ulaw"
    else
      printf '  (원본에 오디오 없음 — 무음 트랙으로 채움)\n' >&2
    fi

    # 4) 카메라 원본을 템플릿으로 MOV 조립. 촬영일시는 --date > 원본 메타데이터 > 파일시각
    local shot="${DATE:-$(video_date "$src")}"
    python3 "$MOVMUX" "$dst" --template "$REF" --video "$tmp/fixed.mjpeg" \
      --audio "$tmp/audio.ulaw" --fps "$FPS" --width "$W" --height "$H" --date "$shot" >&2

    # 5) THM — 첫 프레임을 640xN 으로. 동영상 THM 은 EXIF 가 없다.
    ffmpeg -hide_banner -loglevel error -y -i "$dst" -frames:v 1 -vf "scale=640:-2" \
      -pix_fmt rgb24 "$tmp/vt.ppm"
    cjpeg -quality 90 -sample 2x1 -dct int -outfile "$tmp/vt.jpg" "$tmp/vt.ppm"
    python3 "$JPEGFIX" "$tmp/vt.jpg" "$thm" --merge-tables --quiet

    # 파일 시각도 촬영일시로 맞춘다 (동영상은 EXIF 가 없어 카메라가 파일 시각을 볼 수 있다)
    local stamp; stamp="$(printf '%s' "$shot" | sed -E 's/^([0-9]{4}):([0-9]{2}):([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$/\1\2\3\4\5.\6/')"
    touch -t "$stamp" "$dst" "$thm"

    printf '  %-34s -> DCIM/%s/%s.MOV  (%s @%sfps, %s)\n' "$(basename "$src")" "$folder" "$stem" \
      "$SIZE" "$FPS" "$(du -h "$dst" | cut -f1 | tr -d ' ')"
    printf '  %-34s -> SCN/%s/%s.THM   (%s)   촬영일시 %s\n' "" "$folder" "$stem" \
      "$(exiftool -m -s3 -ImageSize "$thm")" "$shot"
    n=$((n + 1))
  done

  printf '\n※ Motion JPEG 는 용량이 매우 큽니다. 카메라 녹화본 기준 약 500MB/분입니다.\n'
}

# ---------------------------------------------------------------- clean
# macOS 가 FAT32 카드에 남기는 숨김 파일 제거.
# ._XXX 사이드카는 일부 카메라가 손상된 JPEG 으로 오인한다.
cmd_clean() {
  local card="${1:-}"
  [ -n "$card" ] || die "사용법: $0 clean <카드루트>"
  [ -d "$card" ] || die "경로 없음: $card"
  case "$card" in /Volumes/*) ;; *) die "안전상 /Volumes 아래 경로만 허용합니다: $card" ;; esac

  command -v dot_clean >/dev/null 2>&1 && dot_clean -m "$card" 2>/dev/null || true
  find "$card" -name '._*' -delete 2>/dev/null || true
  find "$card" -name '.DS_Store' -delete 2>/dev/null || true
  rm -rf "$card/.Spotlight-V100" "$card/.fseventsd" "$card/.Trashes" "$card/.TemporaryItems" 2>/dev/null || true

  # find 는 .Spotlight-V100/.Trashes 접근 거부로 non-zero 를 반환할 수 있다.
  # pipefail 때문에 그대로 두면 스크립트가 조용히 중단되므로 실패를 흡수한다.
  local left
  left="$( { find "$card" \( -name '._*' -o -name '.DS_Store' \) 2>/dev/null || true; } | wc -l | tr -d ' ')"
  printf '숨김파일 정리 완료 — 남은 항목: %s개\n' "$left"
}

# ---------------------------------------------------------------- deploy
cmd_deploy() {
  local out="${1:-}" card="${2:-}"
  [ -n "$out" ] && [ -n "$card" ] || die "사용법: $0 deploy <out폴더> <카드루트>"
  [ -d "$out" ] || die "소스 폴더 없음: $out"
  [ -d "$card" ] || die "카드 없음: $card"
  case "$card" in /Volumes/*) ;; *) die "안전상 /Volumes 아래 경로만 허용합니다: $card" ;; esac

  local copied=0 d rel target
  while IFS= read -r d; do
    rel="${d#"$out"/}"
    target="$card/$rel"
    [ -d "$target" ] || die "카드에 '$rel' 폴더가 없습니다. 카메라로 사진을 찍어 폴더를 만들게 하세요."
    # -X : 확장속성을 복사하지 않아 ._ 사이드카 생성을 억제
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      cp -X "$f" "$target/" 2>/dev/null || cp "$f" "$target/"
      touch -r "$f" "$target/$(basename "$f")"          # cp 가 바꿔버린 파일 시각을 되돌린다
      printf '  복사: %s/%s\n' "$rel" "$(basename "$f")"
      copied=$((copied + 1))
    done
  done < <(find "$out" -mindepth 2 -maxdepth 2 -type d)

  [ "$copied" -gt 0 ] || die "복사할 파일이 없습니다."
  printf '\n%s개 파일 복사 완료. 숨김파일 정리 중...\n' "$copied"
  cmd_clean "$card"
  printf '\n꺼내기:  diskutil eject "%s"\n' "$card"
}

# ---------------------------------------------------------------- main
case "${1:-}" in
  inspect) shift; cmd_inspect "$@" ;;
  photo)   shift; cmd_photo   "$@" ;;
  video)   shift; cmd_video   "$@" ;;
  deploy)  shift; cmd_deploy  "$@" ;;
  clean)   shift; cmd_clean   "$@" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
