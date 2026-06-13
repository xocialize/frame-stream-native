//
// NativeFrameStream.swift
// FrameStreamNative
//
// FFmpeg-free N:M streaming frame-transform path for ML video processing. Native AVFoundation
// decode (AVAssetReader → BGRA) → an async transform that emits ZERO OR MORE output frames per
// input frame (1:1 upscale/restore, 1:N interpolation) → HEVC encode, always BT.709-tagged.
// Frames stream one at a time so memory stays bounded; cancellation is checked per source frame.
//
// This is a drop-in for format-bridge's `FrameStreamTransform` for the two MLXEngine video
// consumers (mlx-rife-swift, mlx-seedvr2-swift). The encode/append/timing half is ported
// verbatim from that type — it was already pure AVFoundation; only the FFmpeg front-end (probe
// + decode) is replaced here with AVAssetReader.
//
// NATIVE CONTAINERS ONLY (mp4 / mov / m4v · H.264 / HEVC / ProRes). Non-native containers
// (webm / mkv / avi / VP9 / AV1 …) are normalized upstream by format-bridge before this stage
// and are rejected here with `StreamError.unsupportedContainer`. Video-only by design.
//

import AVFoundation
import CoreVideo
import Foundation

/// N:M streaming frame transform: AVFoundation decode → transform (0+ outputs per input) →
/// HEVC/BT.709. FFmpeg-free; native containers only.
public enum NativeFrameStream {

    /// How output presentation timestamps are assigned.
    public enum Timing: Sendable {
        /// Keep each source frame's PTS (valid for 1:1 transforms).
        case preserveSource
        /// Re-time uniformly at `fps` (output index / fps) — for N:M transforms.
        case uniform(fps: Double)
    }

    /// Source video metadata (no decode pass — read from the track).
    public struct VideoInfo: Sendable {
        public let width: Int
        public let height: Int
        public let frameRate: Double
        public let duration: Double
    }

    public struct Output: Sendable {
        /// Source metadata.
        public let sourceWidth: Int
        public let sourceHeight: Int
        public let sourceFrameRate: Double
        public let sourceDuration: Double
        /// Frames written.
        public let frameCount: Int
    }

    public enum StreamError: Error {
        /// A non-native container reached this stage (should be normalized upstream by format-bridge).
        case unsupportedContainer(String)
        case noVideoTrack(String)
        case decodeFailed(String)
        case writeFailed(String)
        case noFramesDecoded
    }

    /// Containers AVFoundation can demux natively. Everything else is normalized upstream.
    private static let nativeExtensions: Set<String> = ["mp4", "mov", "m4v", "qt"]

    private static func ensureNativeContainer(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        guard nativeExtensions.contains(ext) else {
            throw StreamError.unsupportedContainer(
                "\(ext.isEmpty ? "<none>" : ext) — NativeFrameStream handles only native containers "
                + "(mp4/mov/m4v); non-native input must be normalized upstream by format-bridge")
        }
    }

    // MARK: - Probe

    /// Read frame rate + dimensions + duration from the video track. No decode pass.
    /// (mlx-rife-swift needs the source fps up front to compute its uniform output fps.)
    public static func probe(url: URL) async throws -> VideoInfo {
        try ensureNativeContainer(url)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StreamError.noVideoTrack(url.lastPathComponent)
        }
        let size = try await track.load(.naturalSize)
        let frameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        return VideoInfo(width: Int(abs(size.width).rounded()),
                         height: Int(abs(size.height).rounded()),
                         frameRate: Double(frameRate),
                         duration: duration.seconds)
    }

    // MARK: - Run

    /// Stream-process `input` → `output`.
    ///
    /// - Parameters:
    ///   - transform: called once per decoded source frame (BGRA), returns the frames to append
    ///     (BGRA, any size — output dimensions lock from the first emitted frame). Return `[]`
    ///     to consume without emitting (e.g. priming a pairwise window).
    ///   - flush: called once after the last source frame — emit any tail frames (e.g. the
    ///     held `prev` of a pairwise transform).
    public static func run(
        input: URL,
        output: URL,
        timing: Timing = .preserveSource,
        transform: (CVPixelBuffer) async throws -> [CVPixelBuffer],
        flush: () async throws -> [CVPixelBuffer] = { [] }
    ) async throws -> Output {
        try ensureNativeContainer(input)

        // Source metadata + decode setup.
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StreamError.noVideoTrack(input.lastPathComponent)
        }
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration)
        let srcW = Int(abs(naturalSize.width).rounded())
        let srcH = Int(abs(naturalSize.height).rounded())

        // Reader emits BGRA directly (no NV12→BGRA transfer needed, unlike the FFmpeg path).
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw StreamError.decodeFailed("cannot add reader output")
        }
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw StreamError.decodeFailed(reader.error?.localizedDescription ?? "startReading")
        }

        // Lazy HEVC/BT.709 writer (dims from the first emitted frame).
        var writer: AVAssetWriter?
        var writerInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var outIndex = 0
        let uniformDuration: CMTime? = {
            if case .uniform(let fps) = timing {
                let ts: CMTimeScale = 60_000
                return CMTime(value: CMTimeValue((Double(ts) / max(fps, 1)).rounded()), timescale: ts)
            }
            return nil
        }()

        func append(_ pb: CVPixelBuffer, sourcePTS: CMTime) async throws {
            if writer == nil {
                let ow = CVPixelBufferGetWidth(pb), oh = CVPixelBufferGetHeight(pb)
                let w = try AVAssetWriter(outputURL: output, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: ow,
                    AVVideoHeightKey: oh,
                    // BT.709, always tagged (parity with format-bridge's encode tier).
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                    ],
                ])
                input.expectsMediaDataInRealTime = false
                let a = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: ow,
                        kCVPixelBufferHeightKey as String: oh,
                    ])
                w.add(input)
                guard w.startWriting() else {
                    throw StreamError.writeFailed(w.error?.localizedDescription ?? "startWriting")
                }
                w.startSession(atSourceTime: .zero)
                writer = w; writerInput = input; adaptor = a
            }
            guard let inp = writerInput, let adaptor else { return }
            // Video-only track: a bounded wait for readiness is safe (no cross-track interleave).
            while !inp.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                try Task.checkCancellation()
            }
            let t: CMTime
            if let d = uniformDuration {
                t = CMTimeMultiply(d, multiplier: Int32(outIndex))
            } else if sourcePTS.isValid && sourcePTS.isNumeric {
                t = sourcePTS
            } else {
                let fallback = CMTime(value: 1, timescale: CMTimeScale(max(nominalFrameRate, 1)))
                t = CMTimeMultiply(fallback, multiplier: Int32(outIndex))
            }
            guard adaptor.append(pb, withPresentationTime: t) else {
                throw StreamError.writeFailed(writer?.error?.localizedDescription ?? "append \(outIndex)")
            }
            outIndex += 1
        }

        // Decode → transform → append.
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            for out in try await transform(frame) {
                try await append(out, sourcePTS: pts)
            }
        }
        if reader.status == .failed {
            throw StreamError.decodeFailed(reader.error?.localizedDescription ?? "reading")
        }
        for out in try await flush() {
            try await append(out, sourcePTS: .invalid)
        }

        guard let writer, let writerInput else {
            throw StreamError.noFramesDecoded
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw StreamError.writeFailed(writer.error?.localizedDescription ?? "finishWriting")
        }

        return Output(sourceWidth: srcW, sourceHeight: srcH,
                      sourceFrameRate: nominalFrameRate,
                      sourceDuration: duration.seconds,
                      frameCount: outIndex)
    }
}
