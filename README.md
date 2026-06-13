# frame-stream-native

An **FFmpeg-free**, native-AVFoundation N:M streaming frame-transform seam for the MLXEngine video
optimization tier. Module: `FrameStreamNative`.

```
AVAssetReader decode (BGRA) → async transform (0+ outputs per input) → AVAssetWriter HEVC/BT.709
```

Frames stream one at a time so memory stays bounded; cancellation is checked per source frame. The
transform closure emits **zero or more** output frames per input frame — `1:1` (upscale / restore),
`1:N` (interpolation), or `0` (priming a pairwise window).

This is the decode/encode container seam consumed by
[`mlx-rife-swift`](https://github.com/xocialize/mlx-rife-swift) (`frameInterpolate`) and
[`mlx-seedvr2-swift`](https://github.com/xocialize/mlx-seedvr2-swift) (`videoUpscale`). It carries
**no `.unsafeFlags` and no vendored binaries**, so it is a normal versioned SPM dependency —
net-consumable, unlike an FFmpeg-linked path.

## Scope — native containers only

Handles **mp4 / mov / m4v** with **H.264 / HEVC / ProRes**. Non-native containers
(webm / mkv / avi / VP9 / AV1 …) are rejected with `StreamError.unsupportedContainer` — they are
expected to be normalized **upstream** (e.g. by a FormatBridge-style converter) before reaching a
model stage.

## API

```swift
import FrameStreamNative

// Probe metadata (no decode pass) — e.g. to compute a target output fps.
let info = try await NativeFrameStream.probe(url: input)   // .width .height .frameRate .duration

// Stream-transform input → output.
let out = try await NativeFrameStream.run(
    input: input, output: output, timing: .uniform(fps: info.frameRate * 2)
) { (frame: CVPixelBuffer) in
    // return [CVPixelBuffer] — 0+ BGRA frames
    [frame]
}
// out.frameCount, out.sourceWidth/Height, out.sourceFrameRate, out.sourceDuration
```

`Timing` is `.preserveSource` (keep each source PTS, for 1:1) or `.uniform(fps:)` (re-time output
index / fps, for N:M). Output is HEVC, always BT.709-tagged.

## Requirements

macOS 14+. No dependencies beyond AVFoundation / CoreVideo / VideoToolbox.

## License

MIT © 2026 xocialize
