import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins

struct TimelapseFrame: Identifiable {
    let id = UUID()
    let url: URL
    let image: NSImage
    let width: Int
    let height: Int
    let luminance: Double
    let bookmark: Data
    let previewURL: URL
    let isRaw: Bool
}

@MainActor
struct ContentView: View {
    @State private var isLoading = false
    @State private var loadProgress = 0.0
    @State private var loadWorker: SequenceLoadWorker?
    @State private var loadToken = UUID()
    @State private var previewCacheDirectory: URL?
    @State private var previewImage: NSImage?
    @State private var previewImageID: UUID?
    @State private var importReport = ""
    @State private var showImportReport = false
    @State private var frames: [TimelapseFrame] = []
    @State private var selectedID: UUID?
    @State private var message = "Importiere Bilder oder lade ein Projekt."
    @State private var isPlaying = false
    @State private var playbackFPS = 10.0
    @State private var lastPlaybackTime = Date.distantPast
    @State private var exposure = 0.0
    @State private var keyframes: [Int: Double] = [:]
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var lastExportURL: URL?
    @State private var deflickerEnabled = false
    @State private var deflickerCorrections: [Double] = []

    private let imageContext = CIContext()
    private let playbackTimer = Timer.publish(
        every: 1.0 / 30.0, on: .main, in: .common
    ).autoconnect()

    private var selectedIndex: Int? {
        frames.firstIndex { $0.id == selectedID }
    }
    private var selectedFrame: TimelapseFrame? {
        guard let index = selectedIndex else { return nil }
        return frames[index]
    }
    private var selectedIsKeyframe: Bool {
        guard let index = selectedIndex else { return false }
        return keyframes[index] != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .disabled(isExporting || isLoading)
            if isLoading {
                HStack {
                    ProgressView(value: loadProgress)
                    Text(String(format: "Laden: %.0f %%", loadProgress * 100))
                        .font(.caption).monospacedDigit()
                    Button("Abbrechen") {
                        loadWorker?.cancel()
                        message = "Abbruch angefordert. Das aktuelle Bild wird noch beendet."
                    }
                }.padding(.horizontal).padding(.bottom, 10)
            } else if isExporting {
                HStack {
                    ProgressView(value: exportProgress)
                    Text(String(format: "MP4-Export: %.0f %%", exportProgress * 100))
                        .font(.caption).monospacedDigit()
                }.padding(.horizontal).padding(.bottom, 10)
            } else if let url = lastExportURL {
                HStack {
                    Text("MP4: \(url.lastPathComponent)").font(.caption)
                    Spacer()
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }.padding(.horizontal).padding(.bottom, 10)
            }
            Divider()
            preview
            exposureControls
                .disabled(isExporting || isLoading)
            imageInformation
            Divider()
            luminanceChart
            Divider()
            filmstrip
                .disabled(isExporting || isLoading)
            HStack {
                Text(message).lineLimit(2)
                Spacer()
                Text("\(keyframes.count) Keyframes")
                Text("\(frames.count) Bilder")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 1100, minHeight: 800)
        .onReceive(playbackTimer) { advancePlayback(at: $0) }
        .task(id: selectedID) {
            await loadSelectedPreview()
        }
        .sheet(isPresented: $showImportReport) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Importhinweise").font(.title2.bold())
                ScrollView {
                    Text(importReport)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Schließen") { showImportReport = false }
                }
            }.padding(24).frame(width: 650, height: 450)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Timelapse Studio").font(.title2.bold())
                Spacer()
                Picker("Bildrate", selection: $playbackFPS) {
                    Text("5 fps").tag(5.0)
                    Text("10 fps").tag(10.0)
                    Text("15 fps").tag(15.0)
                    Text("30 fps").tag(30.0)
                }.frame(width: 160)
                Button {
                    isPlaying.toggle()
                    lastPlaybackTime = .distantPast
                } label: {
                    Label(isPlaying ? "Pause" : "Abspielen",
                          systemImage: isPlaying ? "pause.fill" : "play.fill")
                }.disabled(frames.count < 2)
            }
            HStack {
                Button("Bilder importieren …") { importImages() }
                Button("Projekt speichern …") { saveProject() }
                    .disabled(frames.isEmpty || isPlaying)
                Button("Projekt laden …") { loadProject() }
                    .disabled(isPlaying)
                Button("Deflicker berechnen") { calculateDeflicker() }
                    .disabled(frames.count < 3 || isPlaying)
                Toggle("Deflicker aktiv", isOn: $deflickerEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(frames.isEmpty || deflickerCorrections.count != frames.count)
                Spacer()
            }
            HStack {
                Button {
                    exportMP4()
                } label: {
                    Label("MP4 exportieren …", systemImage: "film")
                }
                .disabled(frames.isEmpty || isPlaying || isExporting)
                if !importReport.isEmpty {
                    Button("Importhinweise …") { showImportReport = true }
                }
                Text("Full HD · H.264 · ohne Ton")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }.padding()
    }

    private var preview: some View {
        ZStack {
            Color.black.opacity(0.9)
            if let frame = selectedFrame {
                Image(nsImage: adjustedImage(for: frame))
                    .resizable().scaledToFit().padding(16)
            } else {
                Text("Noch keine Bildsequenz geladen")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 180)
    }

    private var exposureControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Belichtung")
                Slider(value: Binding(get: { exposure }, set: { value in
                    exposure = value
                    if let index = selectedIndex, keyframes[index] != nil {
                        keyframes[index] = value
                    }
                }), in: -3...3)
                .frame(width: 220)
                .disabled(selectedIndex == nil || isPlaying)
                Text(String(format: "%+.2f EV", exposure))
                    .monospacedDigit().frame(width: 85)
                Button("Keyframe setzen") {
                    guard let index = selectedIndex else { return }
                    keyframes[index] = exposure
                    message = "Keyframe für Bild \(index + 1) gespeichert."
                }.disabled(selectedIndex == nil || isPlaying)
                Button("Keyframe entfernen") {
                    guard let index = selectedIndex else { return }
                    keyframes.removeValue(forKey: index)
                    exposure = interpolatedExposure(at: index)
                }.disabled(!selectedIsKeyframe || isPlaying)
                Spacer()
            }
            HStack {
                Text(selectedIsKeyframe ? "◆ Dieses Bild ist ein Keyframe."
                     : "Belichtung einstellen und als Keyframe speichern.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Alle Keyframes löschen") {
                    keyframes.removeAll()
                    exposure = 0
                }.disabled(keyframes.isEmpty || isPlaying)
            }
        }.padding(.horizontal).padding(.vertical, 10)
    }

    private var imageInformation: some View {
        HStack {
            if let frame = selectedFrame, let index = selectedIndex {
                Text(frame.url.lastPathComponent).fontWeight(.medium)
                Text("Bild \(index + 1) von \(frames.count)")
                Text(frame.isRaw ? "RAW" : "Bild")
                Spacer()
                Text(String(format: "Original: %.2f %%", frame.luminance * 100))
                Text(String(format: "Deflicker: %+.2f EV", deflickerEV(at: index)))
                Text("\(frame.width) × \(frame.height) Pixel")
            } else { Text("Keine Bilddaten") }
        }.font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal).padding(.bottom, 10)
    }

    private var luminanceChart: some View {
        // Capture plain values before entering Canvas's nonisolated renderer.
        let brightnessValues = frames.map { $0.luminance }
        let keyframePositions = Set(keyframes.keys)
        let selectedPosition = selectedIndex
        let corrections = deflickerCorrections
        let deflickerActive = deflickerEnabled

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Helligkeitsverlauf").font(.headline)
                Spacer()
                Text("Lineare Helligkeit · 0–100 %")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                VStack {
                    Text("100 %")
                    Spacer()
                    Text("50 %")
                    Spacer()
                    Text("0 %")
                }.font(.caption2).foregroundStyle(.secondary).frame(width: 42)
                Canvas { context, size in
                    guard !brightnessValues.isEmpty else { return }
                    func point(_ index: Int, _ value: Double) -> CGPoint {
                        let x = brightnessValues.count == 1 ? size.width / 2
                            : size.width * CGFloat(index) / CGFloat(brightnessValues.count - 1)
                        return CGPoint(x: x, y: size.height * CGFloat(1 - min(max(value, 0), 1)))
                    }
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = size.height * CGFloat(fraction)
                        var grid = Path()
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                    }
                    var curve = Path()
                    for index in brightnessValues.indices {
                        let p = point(index, brightnessValues[index])
                        if index == 0 { curve.move(to: p) }
                        else { curve.addLine(to: p) }
                    }
                    context.stroke(curve, with: .color(.cyan), lineWidth: 2)
                    if deflickerActive, corrections.count == brightnessValues.count {
                        var corrected = Path()
                        for index in brightnessValues.indices {
                            let value = brightnessValues[index] * pow(2.0, corrections[index])
                            let p = point(index, value)
                            if index == 0 { corrected.move(to: p) }
                            else { corrected.addLine(to: p) }
                        }
                        context.stroke(corrected, with: .color(.green), lineWidth: 2)
                    }
                    for index in keyframePositions.sorted() where brightnessValues.indices.contains(index) {
                        let p = point(index, brightnessValues[index])
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                                     with: .color(.orange))
                    }
                    if let index = selectedPosition {
                        let p = point(index, brightnessValues[index])
                        var cursor = Path()
                        cursor.move(to: CGPoint(x: p.x, y: 0))
                        cursor.addLine(to: CGPoint(x: p.x, y: size.height))
                        context.stroke(cursor, with: .color(.primary.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                                     with: .color(keyframePositions.contains(index) ? .orange : .cyan))
                    }
                }.frame(height: 110).padding(.vertical, 5)
            }
            HStack {
                Text(brightnessValues.isEmpty ? "Keine Bilder" : "Bild 1")
                Spacer()
                Text("Cyan: Original · Grün: Deflicker berechnet · Orange: Keyframe")
                Spacer()
                Text(brightnessValues.isEmpty ? "" : "Bild \(brightnessValues.count)")
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal).padding(.vertical, 10)
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(frames.indices, id: \.self) { index in
                    let frame = frames[index]
                    Button {
                        isPlaying = false
                        selectFrame(at: index)
                    } label: {
                        VStack(spacing: 5) {
                            Image(nsImage: frame.image).resizable().scaledToFit()
                                .frame(width: 110, height: 75)
                            HStack(spacing: 4) {
                                if keyframes[index] != nil {
                                    Text("◆").foregroundStyle(.orange)
                                }
                                Text("Bild \(index + 1)")
                            }.font(.caption)
                        }.padding(6)
                            .background(selectedID == frame.id ? Color.accentColor.opacity(0.2) : Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedID == frame.id ? Color.accentColor : Color.clear, lineWidth: 2)
                            }
                    }.buttonStyle(.plain)
                }
            }.padding()
        }.frame(height: 125)
    }

    private func selectFrame(at index: Int) {
        guard frames.indices.contains(index) else { return }
        selectedID = frames[index].id
        exposure = interpolatedExposure(at: index)
    }
    private func interpolatedExposure(at index: Int) -> Double {
        let positions = keyframes.keys.sorted()
        guard let first = positions.first, let last = positions.last else { return 0 }
        if index <= first { return keyframes[first] ?? 0 }
        if index >= last { return keyframes[last] ?? 0 }
        if let exact = keyframes[index] { return exact }
        guard let left = positions.last(where: { $0 < index }),
              let right = positions.first(where: { $0 > index }),
              let a = keyframes[left], let b = keyframes[right] else { return 0 }
        return a + (b - a) * Double(index - left) / Double(right - left)
    }
    private func advancePlayback(at now: Date) {
        guard isPlaying, !isLoading, !isExporting, frames.count > 1,
              now.timeIntervalSince(lastPlaybackTime) >= (1.0 / playbackFPS) - 0.002 else { return }
        lastPlaybackTime = now
        selectFrame(at: ((selectedIndex ?? 0) + 1) % frames.count)
    }
    private func deflickerEV(at index: Int) -> Double {
        guard deflickerEnabled, deflickerCorrections.count == frames.count,
              deflickerCorrections.indices.contains(index) else { return 0 }
        return deflickerCorrections[index]
    }
    private func calculateDeflicker() {
        guard frames.count >= 3 else { return }
        let values = frames.map { log2(max($0.luminance, 0.000001)) }
        var corrections = [Double](repeating: 0, count: frames.count)
        for index in frames.indices {
            let lower = max(0, index - 5)
            let upper = min(frames.count - 1, index + 5)
            let count = Double(upper - lower + 1)
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for neighbor in lower...upper {
                let x = Double(neighbor - index), y = values[neighbor]
                sx += x; sy += y; sxx += x * x; sxy += x * y
            }
            let denominator = count * sxx - sx * sx
            let slope = abs(denominator) > 0.000001 ? (count * sxy - sx * sy) / denominator : 0
            let target = (sy - slope * sx) / count
            corrections[index] = frames[index].luminance > 0.0001
                ? min(max(target - values[index], -1), 1) : 0
        }
        deflickerCorrections = corrections
        deflickerEnabled = true
        message = String(format: "Deflicker berechnet. Größte Korrektur: %.2f EV.",
                         corrections.map { abs($0) }.max() ?? 0)
    }
    private func adjustedImage(for frame: TimelapseFrame) -> NSImage {
        let total = exposure + (selectedIndex.map { deflickerEV(at: $0) } ?? 0)
        let base = previewImageID == frame.id ? (previewImage ?? frame.image) : frame.image
        guard abs(total) > 0.000001, let data = base.tiffRepresentation,
              let input = CIImage(data: data) else { return base }
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = input
        filter.ev = Float(total)
        guard let output = filter.outputImage,
              let rendered = imageContext.createCGImage(output, from: input.extent) else { return base }
        return NSImage(cgImage: rendered, size: base.size)
    }
    private func loadSelectedPreview() async {
        guard let frame = selectedFrame else {
            previewImage = nil
            previewImageID = nil
            return
        }
        let id = frame.id
        let url = frame.previewURL
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard !Task.isCancelled, selectedID == id else { return }
        previewImage = data.flatMap { NSImage(data: $0) }
        previewImageID = id
    }

    private func importImages() {
        guard !isLoading, !isExporting else { return }
        isPlaying = false
        let panel = NSOpenPanel()
        panel.title = "Bildsequenz auswählen – JPG, PNG, TIFF, HEIC oder RAW"
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic, .rawImage]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        beginLoad(sources: urls.map { .file($0) }, strict: false)
    }

    private func beginLoad(sources: [SequenceLoadSource], strict: Bool,
                           project: TimelapseProject? = nil) {
        guard !isLoading, !isExporting else { return }
        isPlaying = false
        isLoading = true
        loadProgress = 0
        let token = UUID()
        loadToken = token
        message = "Bilder werden im Hintergrund entwickelt und analysiert."
        let worker = SequenceLoadWorker(
            sources: sources, strict: strict,
            progress: { fraction, text in
                guard isLoading, loadToken == token else { return }
                loadProgress = fraction
                message = text
            },
            completion: { outcome in
                guard loadToken == token else { return }
                isLoading = false
                loadWorker = nil
                switch outcome {
                case .cancelled:
                    message = "Laden abgebrochen. Der bisherige Stand bleibt erhalten."
                case .failure(let text):
                    message = "Laden fehlgeschlagen: \(text)"
                case .success(let sequence):
                    var restored: [TimelapseFrame] = []
                    for frame in sequence.frames {
                        guard let thumbnail = NSImage(data: frame.thumbnailData) else {
                            removeCache(sequence.cacheDirectory)
                            message = "Ein Filmstreifenbild konnte nicht angezeigt werden."
                            return
                        }
                        restored.append(TimelapseFrame(
                            url: frame.url, image: thumbnail,
                            width: frame.width, height: frame.height,
                            luminance: frame.luminance, bookmark: frame.bookmark,
                            previewURL: frame.previewURL, isRaw: frame.isRaw))
                    }
                    let oldCache = previewCacheDirectory
                    frames = restored
                    previewCacheDirectory = sequence.cacheDirectory
                    previewImage = nil
                    previewImageID = nil
                    keyframes = [:]
                    deflickerCorrections = []
                    deflickerEnabled = false
                    exposure = 0
                    lastExportURL = nil
                    if let project {
                        for keyframe in project.keyframes {
                            keyframes[keyframe.frameIndex] = keyframe.exposure
                        }
                        playbackFPS = project.playbackFPS
                        deflickerCorrections = project.deflickerCorrections ?? []
                        deflickerEnabled = (project.deflickerEnabled ?? false)
                            && deflickerCorrections.count == frames.count
                    }
                    selectFrame(at: 0)
                    if let oldCache { removeCache(oldCache) }
                    importReport = sequence.warnings.joined(separator: "\n\n")
                    let rawCount = frames.filter { $0.isRaw }.count
                    message = "\(frames.count) Bilder geladen, davon \(rawCount) RAW."
                    if !sequence.warnings.isEmpty {
                        message += " \(sequence.warnings.count) Dateien übersprungen; siehe Importhinweise."
                    }
                    if sequence.needsResaving {
                        message += " Bitte Projekt erneut speichern."
                    }
                }
            })
        loadWorker = worker
        worker.start()
    }

    private func removeCache(_ directory: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func exportMP4() {
        guard !frames.isEmpty, !isExporting, !isLoading else { return }
        isPlaying = false
        let panel = NSSavePanel()
        panel.title = "MP4 exportieren – Full HD / H.264"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Timelapse.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let exportFrames = frames.indices.map { index in
            MP4ExportFrame(
                bookmark: frames[index].bookmark,
                exposure: interpolatedExposure(at: index) + deflickerEV(at: index))
        }
        let fps = Int32(playbackFPS)
        isExporting = true
        exportProgress = 0
        lastExportURL = nil
        message = "MP4 wird aus den Originalbildern erstellt. Bitte App geöffnet lassen."
        let worker = MP4ExportWorker(
            frames: exportFrames, destination: destination, fps: fps,
            progress: { value in exportProgress = value },
            completion: { errorText in
                isExporting = false
                if let errorText {
                    message = "Export fehlgeschlagen: \(errorText)"
                } else {
                    lastExportURL = destination
                    message = "MP4 gespeichert: \(destination.lastPathComponent)"
                }
            })
        worker.start()
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.title = "Timelapse-Projekt speichern"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Timelapse-Projekt.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmarks = frames.map { $0.bookmark }
            let project = TimelapseProject(
                version: 2,
                imageNames: frames.map { $0.url.lastPathComponent },
                imageBookmarks: bookmarks,
                playbackFPS: playbackFPS,
                keyframes: keyframes.keys.sorted().map {
                    ExposureKeyframe(frameIndex: $0, exposure: keyframes[$0] ?? 0)
                },
                deflickerCorrections: deflickerCorrections.count == frames.count ? deflickerCorrections : nil,
                deflickerEnabled: deflickerEnabled
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
            message = "Projekt einschließlich Deflicker gespeichert."
        } catch { message = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
    }
    private func loadProject() {
        guard !isLoading, !isExporting else { return }
        isPlaying = false
        let panel = NSOpenPanel()
        panel.title = "Timelapse-Projekt laden"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try JSONDecoder().decode(TimelapseProject.self, from: Data(contentsOf: url))
            guard project.version == 1 || project.version == 2 else {
                message = "Diese Projektversion wird nicht unterstützt."; return
            }
            guard !project.imageNames.isEmpty,
                  [5.0, 10.0, 15.0, 30.0].contains(project.playbackFPS),
                  project.keyframes.allSatisfy({
                      project.imageNames.indices.contains($0.frameIndex)
                          && $0.exposure.isFinite && (-3.0...3.0).contains($0.exposure)
                  }),
                  Set(project.keyframes.map { $0.frameIndex }).count == project.keyframes.count else {
                message = "Ungültige Projekteinstellungen."; return
            }
            if let corrections = project.deflickerCorrections {
                guard corrections.count == project.imageNames.count,
                      corrections.allSatisfy({ $0.isFinite && (-1.0...1.0).contains($0) }) else {
                    message = "Ungültige Deflicker-Werte."; return
                }
            }
            if project.version == 2 {
                guard let bookmarks = project.imageBookmarks,
                      bookmarks.count == project.imageNames.count else {
                    message = "Unvollständige Bildverweise."; return
                }
                beginLoad(sources: bookmarks.map { .bookmark($0) }, strict: true, project: project)
            } else {
                guard project.imageNames == frames.map({ $0.url.lastPathComponent }) else {
                    message = "Altes Projekt: Bilder einmal importieren, Projekt laden und neu speichern."; return
                }
                keyframes = [:]
                for keyframe in project.keyframes {
                    keyframes[keyframe.frameIndex] = keyframe.exposure
                }
                playbackFPS = project.playbackFPS
                deflickerCorrections = project.deflickerCorrections ?? []
                deflickerEnabled = (project.deflickerEnabled ?? false)
                    && deflickerCorrections.count == frames.count
                selectFrame(at: 0)
                message = "Altes Projekt geladen. Bitte neu speichern."
            }
        } catch { message = "Laden fehlgeschlagen: \(error.localizedDescription)" }
    }
}
