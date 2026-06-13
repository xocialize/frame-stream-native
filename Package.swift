// swift-tools-version: 6.2
import PackageDescription

// frame-stream-native — FFmpeg-free N:M streaming frame transform for the MLXEngine video
// optimization tier. Pure AVFoundation/VideoToolbox: AVAssetReader decode (BGRA) → an async
// transform that emits ZERO OR MORE output frames per input frame (1:1 upscale/restore,
// 1:N interpolation) → AVAssetWriter HEVC encode, always BT.709-tagged. Frames stream one at a
// time so memory stays bounded; cancellation is checked per source frame.
//
// This is the decode/encode seam that mlx-rife-swift (frameInterpolate) and mlx-seedvr2-swift
// (videoUpscale) consume. It deliberately carries NO unsafe build flags and NO vendored
// binaries, so it is a normal versioned SPM dependency (net-consumable) — unlike the FFmpeg
// path in format-bridge it replaces for these two packages.
//
// NATIVE CONTAINERS ONLY: mp4 / mov / m4v with H.264 / HEVC / ProRes. Non-native containers
// (webm / mkv / avi / VP9 / AV1 …) are normalized UPSTREAM by format-bridge before reaching
// this stage, and are rejected here with a clear `StreamError.unsupportedContainer`. Module is
// `FrameStreamNative`.
let package = Package(
    name: "frame-stream-native",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrameStreamNative", targets: ["FrameStreamNative"]),
    ],
    targets: [
        .target(
            name: "FrameStreamNative",
            // CVPixelBuffer / CMSampleBuffer aren't Sendable; the engine serializes lifecycle on
            // InferenceActor, so v5 mode keeps region-isolation a warning — same as the wrappers.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FrameStreamNativeTests",
            dependencies: ["FrameStreamNative"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
