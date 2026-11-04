import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

nonisolated struct DecodedTimelapseImage {
    let image: CIImage
    let width: Int
    let height: Int
    let isRaw: Bool
}

// Used by both background import and export. Each worker owns its pipeline.
nonisolated final class TimelapseImagePipeline {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let analysisContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        .cacheIntermediates: false
    ])
    private let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let rawExtensions: Set<String> = [
        "arw", "srf", "sr2", "dng", "crw", "cr2", "cr3", "nef", "nrw",
        "raf", "orf", "rw2", "rwl", "pef", "ptx", "srw", "3fr", "fff",
        "iiq", "mos", "kdc", "dcr", "mrw", "erf", "raw", "x3f"
    ]

    static func isRaw(_ url: URL) -> Bool {
        if rawExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .rawImage) {
            return true
        }
        return false
    }

    func decode(_ url: URL, maxDimension: Int) throws -> DecodedTimelapseImage {
        if Self.isRaw(url) {
            guard let filter = CIRAWFilter(imageURL: url) else {
                throw error("RAW nicht unterstützt oder beschädigt: \(url.lastPathComponent). Die Unterstützung hängt von Kamera und macOS ab.")
            }
            let native = filter.nativeSize
            guard native.width > 0, native.height > 0 else {
                throw error("RAW-Bildgröße nicht lesbar: \(url.lastPathComponent)")
            }
            // Use the same decoder defaults in preview and export, without draft mode.
            filter.scaleFactor = Float(min(1, Double(maxDimension) / Double(max(native.width, native.height))))
            guard let output = filter.outputImage else {
                throw error("RAW-Entwicklung fehlgeschlagen: \(url.lastPathComponent)")
            }
            let normalized = try normalizeAndScale(output, maxDimension: maxDimension)
            return DecodedTimelapseImage(image: normalized, width: Int(native.width),
                                         height: Int(native.height), isRaw: true)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw error("Bild nicht lesbar: \(url.lastPathComponent)")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw error("Bild konnte nicht dekodiert werden: \(url.lastPathComponent)")
        }
        return DecodedTimelapseImage(
            image: CIImage(cgImage: cgImage),
            width: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? cgImage.width,
            height: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? cgImage.height,
            isRaw: false)
    }

    private func normalizeAndScale(_ image: CIImage, maxDimension: Int) throws -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw error("Ungültige Bildgröße nach RAW-Entwicklung.")
        }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let factor = min(1, CGFloat(maxDimension) / max(extent.width, extent.height))
        return normalized.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    }

    func renderPreview(_ image: CIImage) throws -> CGImage {
        guard let rendered = context.createCGImage(image, from: image.extent.integral,
                                                  format: .RGBA8, colorSpace: outputSpace) else {
            throw error("Vorschaubild konnte nicht berechnet werden.")
        }
        return rendered
    }

    func luminance(of image: CGImage) throws -> Double {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage,
              let space = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            throw error("Helligkeitsanalyse fehlgeschlagen.")
        }
        var rgba = [Float](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            analysisContext.render(output, toBitmap: address,
                                   rowBytes: MemoryLayout<Float>.size * 4,
                                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                   format: .RGBAf, colorSpace: space)
        }
        let value = 0.2126 * Double(rgba[0]) + 0.7152 * Double(rgba[1]) + 0.0722 * Double(rgba[2])
        guard value.isFinite else { throw error("Ungültiger Helligkeitswert.") }
        return min(max(value, 0), 1)
    }

    func jpegData(_ image: CGImage, quality: Double = 0.9) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw error("Vorschau konnte nicht kodiert werden.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw error("Vorschau konnte nicht fertiggestellt werden.")
        }
        return data as Data
    }

    func thumbnailData(from image: CGImage) throws -> Data {
        let ciImage = CIImage(cgImage: image)
        let factor = min(1, 320.0 / max(ciImage.extent.width, ciImage.extent.height))
        let small = ciImage.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return try jpegData(renderPreview(small), quality: 0.8)
    }

    private func error(_ text: String) -> NSError {
        NSError(domain: "TimelapseStudio.Image", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
}
