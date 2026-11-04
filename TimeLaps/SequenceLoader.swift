import Foundation

nonisolated enum SequenceLoadSource: Sendable {
    case file(URL)
    case bookmark(Data)
}

nonisolated struct LoadedTimelapseFrame: Sendable {
    let url: URL
    let bookmark: Data
    let thumbnailData: Data
    let previewURL: URL
    let width: Int
    let height: Int
    let luminance: Double
    let isRaw: Bool
}

nonisolated struct LoadedTimelapseSequence: Sendable {
    let frames: [LoadedTimelapseFrame]
    let cacheDirectory: URL
    let warnings: [String]
    let needsResaving: Bool
}

nonisolated enum SequenceLoadOutcome: Sendable {
    case success(LoadedTimelapseSequence)
    case failure(String)
    case cancelled
}

// Image decoding, RAW development, analysis and disk cache writes all run here.
nonisolated final class SequenceLoadWorker: @unchecked Sendable {
    private let sources: [SequenceLoadSource]
    private let strict: Bool
    private let progress: @MainActor @Sendable (Double, String) -> Void
    private let completion: @MainActor @Sendable (SequenceLoadOutcome) -> Void
    private let queue = DispatchQueue(label: "de.mwabner.timelapse.import", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    init(sources: [SequenceLoadSource], strict: Bool,
         progress: @escaping @MainActor @Sendable (Double, String) -> Void,
         completion: @escaping @MainActor @Sendable (SequenceLoadOutcome) -> Void) {
        self.sources = sources
        self.strict = strict
        self.progress = progress
        self.completion = completion
    }

    func start() {
        queue.async { [self] in run() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func run() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelapseStudioPreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pipeline = TimelapseImagePipeline()
            var frames: [LoadedTimelapseFrame] = []
            var warnings: [String] = []
            var needsResaving = false
            for (index, source) in sources.enumerated() {
                if isCancelled {
                    try? FileManager.default.removeItem(at: directory)
                    report(.cancelled)
                    return
                }
                do {
                    let loaded: (LoadedTimelapseFrame, Bool) = try autoreleasepool {
                        var stale = false
                        let url: URL
                        switch source {
                        case .file(let fileURL): url = fileURL
                        case .bookmark(let data):
                            url = try URL(resolvingBookmarkData: data,
                                          options: [.withSecurityScope, .withoutUI],
                                          relativeTo: nil, bookmarkDataIsStale: &stale)
                        }
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        let decoded = try pipeline.decode(url, maxDimension: 1200)
                        let preview = try pipeline.renderPreview(decoded.image)
                        let luminance = try pipeline.luminance(of: preview)
                        let previewURL = directory.appendingPathComponent(String(format: "%06d.jpg", index))
                        try pipeline.jpegData(preview).write(to: previewURL, options: .atomic)
                        let thumbnail = try pipeline.thumbnailData(from: preview)
                        let bookmark = try url.bookmarkData(
                            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                            includingResourceValuesForKeys: nil, relativeTo: nil)
                        return (LoadedTimelapseFrame(url: url, bookmark: bookmark,
                                                    thumbnailData: thumbnail, previewURL: previewURL,
                                                    width: decoded.width, height: decoded.height,
                                                    luminance: luminance, isRaw: decoded.isRaw), stale)
                    }
                    frames.append(loaded.0)
                    needsResaving = needsResaving || loaded.1
                } catch {
                    if strict { throw error }
                    warnings.append(error.localizedDescription)
                }
                let fraction = Double(index + 1) / Double(max(1, sources.count))
                let text = "Bild \(index + 1) von \(sources.count) geladen und analysiert"
                let callback = progress
                Task { @MainActor in callback(fraction, text) }
            }
            if isCancelled {
                try? FileManager.default.removeItem(at: directory)
                report(.cancelled)
                return
            }
            guard !frames.isEmpty else {
                throw NSError(domain: "TimelapseStudio.Import", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: warnings.first ?? "Keine lesbaren Bilder gefunden."])
            }
            report(.success(LoadedTimelapseSequence(frames: frames, cacheDirectory: directory,
                                                    warnings: warnings, needsResaving: needsResaving)))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            report(isCancelled ? .cancelled : .failure(error.localizedDescription))
        }
    }

    private func report(_ outcome: SequenceLoadOutcome) {
        let callback = completion
        Task { @MainActor in callback(outcome) }
    }
}
