import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import ImageIO

// Nonisolated keeps the background encoder independent of Xcode's
// default MainActor isolation. Requires Swift 6.2 or newer (Xcode 26+).
nonisolated struct MP4ExportFrame: Sendable {
    let bookmark: Data
    let exposure: Double
}

// All mutable encoder state is confined to one serial queue.
// The only callbacks leaving that queue run on MainActor.
nonisolated final class MP4ExportWorker: @unchecked Sendable {
    private let frames: [MP4ExportFrame]
    private let destination: URL
    private let fps: Int32
    private let progress: @MainActor @Sendable (Double) -> Void
    private let completion: @MainActor @Sendable (String?) -> Void
    private let queue = DispatchQueue(label: "de.mwabner.timelapse.mp4", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pipeline = TimelapseImagePipeline()
    private let width = 1920
    private let height = 1080
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var temporaryURL: URL?
    private var index = 0
    private var finalizing = false
    private var destinationAccessed = false

    init(frames: [MP4ExportFrame], destination: URL, fps: Int32,
         progress: @escaping @MainActor @Sendable (Double) -> Void,
         completion: @escaping @MainActor @Sendable (String?) -> Void) {
        self.frames = frames
        self.destination = destination
        self.fps = fps
        self.progress = progress
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            do { try begin() }
            catch { fail(error.localizedDescription) }
        }
    }

    private func begin() throws {
        guard !frames.isEmpty, [5, 10, 15, 30].contains(Int(fps)) else {
            throw exportError("Ungültige Bildsequenz oder Bildrate.")
        }
        destinationAccessed = destination.startAccessingSecurityScopedResource()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Timelapse-\(UUID().uuidString).mp4")
        temporaryURL = temp
        let assetWriter = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        writer = assetWriter
        assetWriter.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        guard assetWriter.canAdd(videoInput) else {
            throw exportError("Der H.264-Encoder konnte nicht eingerichtet werden.")
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)
        input = videoInput
        adaptor = pixelAdaptor
        assetWriter.add(videoInput)
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? exportError("Videoexport konnte nicht gestartet werden.")
        }
        assetWriter.startSession(atSourceTime: .zero)
        videoInput.requestMediaDataWhenReady(on: queue) { [self] in pump() }
    }

    private func pump() {
        guard !finalizing, let writer, let input, let adaptor else { return }
        guard writer.status == .writing else {
            fail(writer.error?.localizedDescription ?? "Der Videoencoder wurde beendet.")
            return
        }
        while input.isReadyForMoreMediaData && index < frames.count {
            do {
                try autoreleasepool {
                    let buffer = try renderFrame(frames[index], adaptor: adaptor)
                    let timestamp = CMTime(value: Int64(index), timescale: fps)
                    guard adaptor.append(buffer, withPresentationTime: timestamp) else {
                        throw writer.error ?? exportError("Bild \(index + 1) konnte nicht geschrieben werden.")
                    }
                }
                index += 1
                if index == frames.count || index % max(1, frames.count / 100) == 0 {
                    // Reserve the last 5 percent for encoder finalization.
                    let value = 0.95 * Double(index) / Double(frames.count)
                    let callback = progress
                    Task { @MainActor in callback(value) }
                }
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        if index == frames.count {
            finalizing = true
            writer.endSession(atSourceTime: CMTime(value: Int64(frames.count), timescale: fps))
            input.markAsFinished()
            writer.finishWriting { [self] in
                queue.async { [self] in finish() }
            }
        }
    }

    private func renderFrame(_ frame: MP4ExportFrame,
                             adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        var stale = false
        let url = try URL(resolvingBookmarkData: frame.bookmark,
                          options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        // Raster and RAW use the same development pipeline as import.
        let decoded = try pipeline.decode(url, maxDimension: max(width, height))
        let original = decoded.image
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = original
        filter.ev = Float(frame.exposure)
        guard let corrected = filter.outputImage else {
            throw exportError("Belichtungskorrektur fehlgeschlagen.")
        }
        let scale = min(CGFloat(width) / corrected.extent.width,
                        CGFloat(height) / corrected.extent.height)
        let scaled = corrected.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: (CGFloat(width) - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (CGFloat(height) - scaled.extent.height) / 2 - scaled.extent.minY))
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        let result = positioned.composited(over: black).cropped(to: bounds)
        guard let pool = adaptor.pixelBufferPool else {
            throw exportError("Kein Bildspeicher für den Videoencoder verfügbar.")
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw exportError("Videobild konnte nicht angelegt werden (\(status)).")
        }
        context.render(result, to: pixelBuffer, bounds: bounds, colorSpace: colorSpace)
        return pixelBuffer
    }

    private func finish() {
        guard writer?.status == .completed, let temporaryURL else {
            fail(writer?.error?.localizedDescription ?? "MP4 konnte nicht fertiggestellt werden.")
            return
        }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                // The save panel has already asked whether to replace this file.
                _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                try manager.copyItem(at: temporaryURL, to: destination)
            }
            cleanup()
            let reportProgress = progress
            let reportCompletion = completion
            Task { @MainActor in
                reportProgress(1)
                reportCompletion(nil)
            }
        } catch {
            fail("MP4 konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    private func fail(_ text: String) {
        finalizing = true
        if writer?.status == .writing { writer?.cancelWriting() }
        cleanup()
        let callback = completion
        Task { @MainActor in callback(text) }
    }

    private func cleanup() {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        if destinationAccessed {
            destination.stopAccessingSecurityScopedResource()
            destinationAccessed = false
        }
        adaptor = nil
        input = nil
        writer = nil
    }

    private func exportError(_ text: String) -> NSError {
        NSError(domain: "TimelapseStudio.MP4", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
}
