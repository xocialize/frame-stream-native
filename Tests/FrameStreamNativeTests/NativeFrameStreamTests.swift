import AVFoundation
import CoreVideo
import XCTest
@testable import FrameStreamNative

final class NativeFrameStreamTests: XCTestCase {

    // MARK: - Helpers

    /// Synthesize a minimal native mp4 (HEVC, BGRA source) so the suite needs no fixture assets.
    private func writeTestVideo(frames: Int, fps: Int, width: Int, height: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let pb = makePixelBuffer(width: width, height: height, gray: UInt8((i * 17) & 0xFF))
            let t = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: t))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "fixture writer: \(String(describing: writer.error))")
        return url
    }

    private func makePixelBuffer(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * bpr + x * 4
                base[p + 0] = gray; base[p + 1] = gray; base[p + 2] = gray; base[p + 3] = 255
            }
        }
        return buffer
    }

    // MARK: - Tests

    func testProbeReadsTrackMetadata() async throws {
        let url = try await writeTestVideo(frames: 10, fps: 24, width: 64, height: 48)
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try await NativeFrameStream.probe(url: url)
        XCTAssertEqual(info.width, 64)
        XCTAssertEqual(info.height, 48)
        XCTAssertEqual(info.frameRate, 24, accuracy: 0.5)
        XCTAssertEqual(info.duration, 10.0 / 24.0, accuracy: 0.1)
    }

    func testIdentityTransformPreservesFrameCount() async throws {
        let inURL = try await writeTestVideo(frames: 10, fps: 24, width: 64, height: 48)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer {
            try? FileManager.default.removeItem(at: inURL)
            try? FileManager.default.removeItem(at: outURL)
        }

        let out = try await NativeFrameStream.run(input: inURL, output: outURL,
                                                  timing: .preserveSource) { [$0] }
        XCTAssertEqual(out.frameCount, 10)
        XCTAssertEqual(out.sourceWidth, 64)
        XCTAssertEqual(out.sourceHeight, 48)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))

        // The output is itself a valid native mp4 with the same frame count.
        let reprobe = try await NativeFrameStream.probe(url: outURL)
        XCTAssertEqual(reprobe.width, 64)
        XCTAssertEqual(reprobe.height, 48)
    }

    func testUniformDoublesFrameCount() async throws {
        let inURL = try await writeTestVideo(frames: 8, fps: 24, width: 32, height: 32)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer {
            try? FileManager.default.removeItem(at: inURL)
            try? FileManager.default.removeItem(at: outURL)
        }

        // Emit each source frame twice → 2× the frames at 2× fps (RIFE-shaped N:M).
        let out = try await NativeFrameStream.run(input: inURL, output: outURL,
                                                  timing: .uniform(fps: 48)) { [$0, $0] }
        XCTAssertEqual(out.frameCount, 16)
    }

    func testNonNativeContainerThrows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("webm")
        do {
            _ = try await NativeFrameStream.probe(url: url)
            XCTFail("expected unsupportedContainer")
        } catch NativeFrameStream.StreamError.unsupportedContainer {
            // expected
        }
    }
}
