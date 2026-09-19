# Technical notes

How the Kodak PIXPRO FZ55 (firmware 1.06) stores photos and videos, what it rejects, and how each cause was isolated. Everything here comes from taking apart files the camera recorded, then feeding the camera variations of them until only one explanation was left.

The user-facing guide is the [README](../README.md).

---

## Card layout

```
DCIM/100KFZ55/100_0348.JPG    photo
DCIM/100KFZ55/100_0383.MOV    video
SCN/100KFZ55/100_0348.THM     preview for the photo  (same name, different folder)
SCN/100KFZ55/100_0383.THM     preview for the video
```

- Folder `100KFZ55`, file names `100_` + four digits (DCF style). Not `PICT0001`.
- **`SCN/*.THM` is what the camera draws on screen.** A JPG without a valid `.THM` is listed during playback but shown as `?`.
- Deleting a file on the camera deletes its `.THM` as well. A `.THM` without a partner is ignored and can be deleted safely.
- When the last file is deleted on the camera, the camera removes `DCIM/100KFZ55` too. Creating it again with `mkdir` works.
- The card is FAT32, so no single file can exceed 4 GB.

### Numbering

- Playback follows file-number order. EXIF dates only affect what's displayed and the camera's date view. This matches the DCF convention and everything we observed.
- New shots get the next number after **max(largest number on the card, last number the camera used)**. Observed twice:
  - Card max `0382` → the next shot was `0383`.
  - After deleting `0382` and `0383` (card max now `0381`), the next shot was `0384`.
- A camera-made JPG + THM pair still plays after both files are renamed (verified). That makes reordering a rename-only operation.

---

## Photos

### What the camera writes

`.JPG` and `.THM` share the same encoding.

| Item | Value |
|---|---|
| Coding | Baseline DCT, Huffman |
| Subsampling | YCbCr 4:2:2 — sampling factors **`2x1 / 1x1 / 1x1`** |
| Quantization tables | **Two**: luma → table 0, **chroma → table 1** (one DQT segment, 132 bytes) |
| Huffman tables | The four standard tables from JPEG Annex K (one DHT segment, 418 bytes) |
| Segment order | `APP1 [APP5 APP6] DQT SOF0 DHT SOS` |
| EXIF | Big-endian (MM), Exif 2.3, sRGB, YCbCrPositioning = co-sited |
| | InteropIndex `R98 - DCF basic file (sRGB)` |
| | Make `JK Imaging, Ltd.`, Model `KODAK PIXPRO FZ55` |
| Embedded thumbnail | 160×120 (IFD1) |
| APP5 / APP6 | Kodak-specific blocks. **Not required** (verified). |
| Photo `.THM` | 640×480 JPEG carrying the same EXIF as the photo |

The camera never writes `APP0` (JFIF), `APP2` (ICC profile), or `COM` segments.

The 418-byte DHT is exactly Annex K: 2 × 29 (DC tables) + 2 × 179 (AC tables) + 2. The 132-byte DQT is two 8-bit tables: 2 × 65 + 2.

### How the converter builds one

1. Decode and resize the source with ffmpeg to a PPM.
2. Encode with **`cjpeg -sample 2x1 -dct int`** (libjpeg). This produces the canonical `2x1/1x1/1x1` factors with chroma on table 1.
3. Clone the reference photo's EXIF (`exiftool -tagsFromFile ref -all:all`). Then fix the image size, orientation and dates, and insert a fresh 160×120 thumbnail.
4. `pixpro-jpegfix.py --merge-tables`: drop APP0/APP2/COM, merge cjpeg's two DQT and four DHT segments into one each, and reorder to `DQT SOF0 DHT`.
5. Build the 640×480 `.THM` the same way, cloning EXIF from the reference `.THM`.

---

## Videos

### What the camera writes

| Item | Measured | Manual says |
|---|---|---|
| Video | Motion JPEG, 1920×1080, 30 fps, **yuvj420p (4:2:0)** | "Motion JPEG" |
| Audio | **`pcm_mulaw` (μ-law), 44.1 kHz, mono** | "Linear PCM" — **wrong** |
| Bitrate | ~67 Mbit/s (~500 MB per minute) | not stated |

### Motion JPEG frames

```
DQT SOF0 DHT SOS                          no APP0 / COM / APP1
DQT = 132 B   DHT = 418 B   id1: 2x2 -> q0   id2: 1x1 -> q1   id3: 1x1 -> q1
```

Because video is 4:2:0, ffmpeg's MJPEG encoder already writes canonical sampling factors. It still adds APP0 and COM to every frame and puts chroma on table 0. The converter fixes that on the raw stream before muxing:
`pixpro-jpegfix.py --stream --merge-tables --chroma-qtable 1`.

### MOV container

```
wide  mdat  moov  free                    no ftyp
mdat : [15 video frames][22,048 B of audio ≈ 0.5 s] repeated
       every frame padded to a multiple of 16 bytes
moov : mvhd  timescale 3000
       video trak : tkhd flags 0xf, no edts, mdhd timescale 3000, stts (N, 100)
                    hdlr vendor 'KODA', name 'PIXPRO FZ55', vmhd graphicsmode 64
                    stsd 'jpeg', 88 bytes (vendor 0, quality 0), one frame per chunk
       audio trak : mdhd timescale 44100, stsd 'ulaw' version 1 (52 bytes), stsc (1, 22048, 1)
```

**ffmpeg's MOV muxer can't be used.** Its files play in fast-forward on the camera while the audio stays at normal speed. They look perfect on a computer, which is why the problem is easy to miss. ffmpeg always writes `ftyp` and `edts/elst`, interleaves audio in small pieces, and fills `stsd`/`hdlr` differently.

Rather than guess which difference trips the firmware, `pixpro-movmux.py` takes the reference video's `moov` atom as a template. It reuses its bytes unchanged and replaces only durations, sample sizes, chunk offsets, dimensions, and timestamps. It then writes `mdat` in the camera's 15-frames-then-half-a-second-of-audio pattern.

### Dates

- The camera stores creation/modification times in `mvhd`, `tkhd` and `mdhd` as **local time, with no UTC conversion**. The muxer does the same.
- MP4 files from phones store UTC, as the standard requires. The converter reads them with exiftool's `QuickTimeUTC` option to get local time.
- Video has no EXIF, so the camera might use the file's modification time instead. Both the MOV and its `.THM` get that time set to the capture date. `deploy` restores it after copying (`cp` resets it).

### Video `.THM`

- 640 × N, keeping the video's aspect ratio (640×360 for 16:9). Photo previews are 640×480.
- 4:2:2 baseline, DQT 132 / DHT 418, **no EXIF at all** (`DQT SOF0 DHT SOS`).
- Generated from the first frame.

---

## Pitfalls

1. **Encoding stills with ffmpeg's MJPEG encoder.** With `-pix_fmt yuvj422p` it writes sampling factors `2x2/1x2/1x2` and points chroma at table 0. Mathematically that's still 4:2:2, but in unreduced form, and the camera's hardware decoder rejects it: the photo shows `?`. exiftool reports "YCbCr4:2:2 (2 1)" for both, so it can't show you the difference; you have to read SOF0 yourself. `-force_duplicated_matrix` doesn't help either. It writes two tables, but they're identical, and chroma still uses table 0.
2. **Re-saving the reference video.** Even `ffmpeg -c copy` rewrites the container: it adds `ftyp` and changes the video `mdhd` timescale from 3000 to 12000, among other things. Compare against such a file and everything looks like a match. The muxer refuses templates that contain `ftyp`.
3. **exiftool naming.** `TimeScale` is the `mvhd` value; `MediaTimeScale` is per-track `mdhd`. They're easy to confuse.
4. **macOS `._*` files.** Finder writes AppleDouble sidecars such as `._100_0349.JPG` onto FAT32 cards. The camera may treat them as corrupt JPEGs. Use `cp -X` and `dot_clean`.
5. **exiftool numeric tags need `#`.** `-Orientation=1` goes through the print conversion and actually writes **3 (Rotate 180)**. Write `-Orientation#=1`. The same applies to ColorSpace, YCbCrPositioning, and ResolutionUnit.
6. **MakerNotes.** The camera's MakerNotes are malformed by exiftool's standards. Copying them needs `-m` (ignore minor errors).

---

## Verification history

Each row is a set of files put on the card and checked on the camera.

### Photos

| Files on the card | Result | Conclusion |
|---|---|---|
| Camera JPG + camera THM, both renamed | plays | Renamed copies are accepted; there's no hidden index. |
| Camera JPG + our (ffmpeg-encoded) THM | `?` | The THM is what fails. |
| Our (ffmpeg-encoded) JPG + camera THM | plays | The screen is drawn from the THM. |
| cjpeg JPG + THM, with APP5/APP6 | plays | |
| cjpeg JPG + THM, without APP5/APP6 | plays | APP5/APP6 aren't needed. |

### Videos

| MOV built with | Result |
|---|---|
| ffmpeg muxer, video `mdhd` 3000, `mvhd` 1000 | picture fast-forwards, audio normal |
| ffmpeg muxer, video `mdhd` 12000, `mvhd` 1000 | same |
| ffmpeg muxer, `mdhd` 3000, `mvhd` 3000, at 720p and at 1080p | same, so neither timescale nor resolution is the cause |
| `pixpro-movmux.py` with a camera template, 720p | **plays correctly** |

Not yet verified on the camera: 1080p and 60 fps output from `pixpro-movmux.py`.
