# metalkey

A fast green-screen keyer for Apple Silicon. metalkey replaces the green background behind a person with an image or a video. The whole frame pipeline runs on the GPU (Metal) and the video encoder (VideoToolbox), so a 1080p50 clip renders several times faster than real time while the CPU stays mostly idle.

It is written in Swift and Metal. ffmpeg is used only at the end, to copy the audio and subtitles from the source into the result without re-encoding them.

## What it does

For every frame:

1. **Decode.** AVFoundation decodes the source with the hardware decoder. The frames are handed to Metal as textures, with no copies.
2. **Key.** Each output pixel is resampled from the source (Lanczos-3 luma, bicubic chroma), converted to RGB, and given an alpha from a *dominance matte*:

   ```
   d     = G − max(R, B)                       (= min(G−R, G−B))
   alpha = 255 − clip((d − lo) × gain, 0, 255)
   ```

   A pixel becomes background only when its green beats *both* red and blue by more than `lo`. Optional garbage boxes force areas transparent.
3. **Smooth and despill.** The matte gets a small Gaussian blur (sigma 1.2) so edges are not stair-stepped by 4:2:0 chroma. Green spill on hair and shoulders is pulled back with the same formula as FFmpeg's `despill=type=green`.
4. **Composite.** The background (image or looping video) is scaled to cover the frame and centre-cropped; still images get a little moving grain so they don't look pasted on. The person is composited over it and written straight into the encoder's NV12 buffer.
5. **Encode and remux.** VideoToolbox encodes H.264 (High profile). Then `ffmpeg -c copy` adds the source audio (bit-exact) and the subtitles.

It can also **zoom out to a vertical frame** in the same pass: `--out-size 1080x1920 --zoom 85 --center-x <x>` makes a 9:16 video straight from a 16:9 clip. The window is bottom-anchored, and the area above the original frame, where there was never any green screen, becomes background too.

## Why not ffmpeg `chromakey`?

`chromakey` (and `colorkey`) measure the distance from the key colour in the U/V chroma plane. That works for a bright, saturated, evenly lit screen. Real-world screens are often darker and less saturated, and in the U/V plane a dark, dull green sits close to dark clothing and to skin. On such footage there is no good similarity setting: a value low enough to keep the face makes a dark jacket see-through, and a value high enough to clear the screen eats the person.

The dominance key asks a different question, "is green clearly the strongest channel here?", which dark clothing and skin never satisfy. It holds up on dim, uneven green where `chromakey` fails.

The same key in plain FFmpeg, for reference (slow, but useful for comparison):

```bash
ffmpeg -i in.mp4 -loop 1 -i bg.png -filter_complex "\
[1:v]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,format=gbrp[bg];\
[0:v]scale=flags=bicubic+full_chroma_int+full_chroma_inp+accurate_rnd,format=gbrp,split=3[c][m1][m2];\
[m1]colorchannelmixer=gr=-1:gg=1:gb=0,extractplanes=g[d1];\
[m2]colorchannelmixer=gr=0:gg=1:gb=-1,extractplanes=g[d2];\
[d1][d2]blend=all_mode=darken,lut=c0='255-clip((val-12)*12,0,255)',gblur=sigma=1.2[a];\
[c]despill=type=green,format=gbrp[c2];[c2][a]alphamerge[fg];\
[bg][fg]overlay=shortest=1,format=yuv420p[v]" \
-map "[v]" -map 0:a -c:v libx264 -crf 18 -c:a copy out.mp4
```

## Install

With Homebrew (Apple Silicon; pulls in ffmpeg):

```bash
brew install matija2209/tap/metalkey
```

From source. Requirements: a Mac with Apple Silicon, macOS 12 or later, Xcode or the Command Line Tools (for `swift`), and ffmpeg for the final remux.

```bash
brew install ffmpeg
git clone https://github.com/matija2209/metalkey.git
cd metalkey
swift build -c release
ln -sf "$PWD/.build/release/metalkey" ~/.local/bin/metalkey   # or any directory on your PATH
```

You do not need the Metal compiler (`xcrun metal`). The shader source is embedded in the binary and compiled at runtime with `device.makeLibrary(source:)`.

Prebuilt arm64 binaries are attached to each [GitHub release](../../releases). They are not notarised, so after downloading run `xattr -d com.apple.quarantine metalkey`.

## Usage

```
metalkey <in.mp4> <bg.png|bg.jpg|bg.mp4|bg.mov> <out.mp4> [options]
metalkey <in.mp4> --preview <out.png> [--at S] [options]
```

**Tune first.** Render one keyed frame on magenta. Magenta is the opposite of green, so leftover green, holes and see-through clothing stand out:

```bash
metalkey talk.mp4 --preview check.png --at 5
metalkey talk.mp4 --preview check.png --at 5 --lo 18 --gain 8
```

**16:9, replace the background:**

```bash
metalkey talk.mp4 wall.png talk_wall.mp4
```

**9:16 from a 16:9 clip, zoomed out, with a subtitle file:**

```bash
metalkey talk.mp4 wall_9x16.png talk_9x16.mp4 \
  --out-size 1080x1920 --zoom 85 --center-x 1034 --subs talk_9x16.srt
```

`--center-x` is the horizontal centre of the person in source pixels; `--zoom 100` is a plain centre crop, lower values show more of the frame.

**Video background** (looped if shorter than the clip; no grain is added):

```bash
metalkey talk.mp4 park.mp4 talk_park.mp4
```

**Garbage boxes** for things on set that are not green (a light stand, a cable, the edge of the cloth). Coordinates are `x0:y0:x1:y1` in *source* pixels, even when rendering 9:16:

```bash
metalkey talk.mp4 wall.png out.mp4 --garbage 1780:1000:1920:1080 --garbage 0:0:120:200
GARBAGE="1780:1000:1920:1080 0:0:120:200" metalkey talk.mp4 wall.png out.mp4
```

**A 10 s test from 0:03:**

```bash
metalkey talk.mp4 wall.png test.mp4 --start 3 --length 10
```

### Options

| Option | Default | Meaning |
|---|---|---|
| `--lo N` | 12 | green dominance (0–255) a pixel needs before it starts to vanish |
| `--gain N` | 12 | how fast it goes from opaque to transparent; higher = harder edge |
| `--out-size WxH` | source size | output size (even numbers) |
| `--zoom Z` | 100 | zoom-out percent for `--out-size`; the window is bottom-anchored |
| `--center-x N` | source centre | window centre in source pixels |
| `--garbage x0:y0:x1:y1` | `$GARBAGE` | box forced transparent, source pixels; repeatable (max 8) |
| `--grain N` | `$GRAIN` or 5 | moving grain on a still background; 0 = off |
| `--start S` | 0 | start time in seconds |
| `--length S` | 0 (to the end) | seconds to render |
| `--subs file.srt` | source's subtitles | subtitle file to mux (as `mov_text`) |
| `--no-subs` | | carry no subtitle track |
| `--bitrate M` | 0.12 bits/pixel × fps | H.264 average bitrate in Mbit/s (12.4 at 1080×1920@50) |
| `--sigma S` | 1.2 | matte blur sigma |
| `--chroma-loc center\|left` | center | 4:2:0 chroma siting of the source |
| `--video-only` | | skip the ffmpeg remux; write the video stream only |
| `--preview F.png` | | render one frame on magenta and exit |
| `--at S` | 3 | time of the preview frame |

### Tuning on magenta

| What you see | Fix |
|---|---|
| Green or dark blotches left in corners | lower `--lo` (12 → 8) or raise `--gain` |
| Holes or a purple tint on dark clothes | raise `--lo` (12 → 18) |
| Hard, cut-out edge on hair | lower `--gain` (12 → 8) |
| Something on set that isn't green | `--garbage` box; a colour key cannot remove what isn't green |

## Benchmark

A 23 s, 1080p50 talking-head clip (1162 frames), rendered to 1080×1920 with a zoom-out and a still background, on a MacBook Pro with an M1 Pro:

| | Time | Speed | CPU |
|---|---|---|---|
| FFmpeg filter graph above + libx264 | ~40 s | ~29 fps | all cores |
| metalkey | ~6.5 s | ~180–190 fps | ~18 % |

That is about **6× faster**. Against the FFmpeg render the output has an SSIM of **0.992**, and the audio stream is bit-identical to the source (same MD5).

## Differences from the FFmpeg reference

- The Gaussian matte blur uses an exact kernel (FFmpeg `gblur` is an IIR approximation), and compositing is done in RGB rather than in yuv420. Edges come out marginally smoother.
- Grain has the same strength as `noise=alls=N:allf=t` but a different random pattern.
- Chroma siting defaults to `center`, which is what FFmpeg's swscale assumes; `--chroma-loc left` follows the H.264 tag instead.

## Limitations

- Apple Silicon and macOS only (Metal, VideoToolbox).
- Output is always H.264 in MP4, BT.709, 8-bit 4:2:0. No ProRes, HEVC, alpha output or HDR.
- Audio is copied when it is AAC; anything else is re-encoded to AAC 192k by ffmpeg. ffmpeg must be on `PATH` unless you use `--video-only`.
- It is a colour key. A wrinkled or unevenly lit screen, a screen too small for the frame, or a person wearing green needs ML matting (e.g. Robust Video Matting) instead.
- Single clip in, single clip out: no batch mode, no GUI.

## License

[MIT](LICENSE) © 2026 Matija Žiberna
