import Foundation

nonisolated struct TimelapseProject: Codable, Sendable {
    let version: Int
    let imageNames: [String]
    let imageBookmarks: [Data]?
    let playbackFPS: Double
    let keyframes: [ExposureKeyframe]
    let deflickerCorrections: [Double]?
    let deflickerEnabled: Bool?

    init(version: Int, imageNames: [String], imageBookmarks: [Data]?,
         playbackFPS: Double, keyframes: [ExposureKeyframe],
         deflickerCorrections: [Double]? = nil, deflickerEnabled: Bool? = nil) {
        self.version = version
        self.imageNames = imageNames
        self.imageBookmarks = imageBookmarks
        self.playbackFPS = playbackFPS
        self.keyframes = keyframes
        self.deflickerCorrections = deflickerCorrections
        self.deflickerEnabled = deflickerEnabled
    }
}

nonisolated struct ExposureKeyframe: Codable, Sendable {
    let frameIndex: Int
    let exposure: Double
}
