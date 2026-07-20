import Foundation
import iPocketTubeCore

actor LocalDubbingCache {
    struct ResolvedResult: Equatable, Sendable {
        let result: LocalDubbingResult
        let audioURL: URL
        let transcriptURL: URL
    }

    private let outputRootDirectory: URL
    private let workRootDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = baseDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dubbingRoot = applicationSupport
            .appendingPathComponent("AxrTubeDubbing", isDirectory: true)
        self.outputRootDirectory = dubbingRoot
            .appendingPathComponent("Outputs", isDirectory: true)
            .appendingPathComponent("v\(LocalDubbingPolicy.algorithmVersion)", isDirectory: true)
        self.workRootDirectory = dubbingRoot
            .appendingPathComponent("Work", isDirectory: true)
            .appendingPathComponent("v\(LocalDubbingPolicy.algorithmVersion)", isDirectory: true)
    }

    func load(videoID: String, cacheIdentity: String? = nil) -> ResolvedResult? {
        let directory = outputDirectory(videoID: videoID)
        let recordURL = directory.appendingPathComponent("result.json")
        guard let data = try? Data(contentsOf: recordURL),
              let result = try? JSONDecoder().decode(LocalDubbingResult.self, from: data),
              result.algorithmVersion == LocalDubbingPolicy.algorithmVersion,
              result.videoID == videoID,
              cacheIdentity == nil || result.cacheIdentity == cacheIdentity else { return nil }
        let audioURL = directory.appendingPathComponent(result.audioFilename)
        let transcriptURL = directory.appendingPathComponent(result.transcriptFilename)
        guard fileManager.fileExists(atPath: audioURL.path),
              fileManager.fileExists(atPath: transcriptURL.path),
              ((try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            return nil
        }
        return ResolvedResult(result: result, audioURL: audioURL, transcriptURL: transcriptURL)
    }

    func store(
        result: LocalDubbingResult,
        temporaryAudioURL: URL,
        transcriptText: String
    ) throws -> ResolvedResult {
        let directory = outputDirectory(videoID: result.videoID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent(result.audioFilename)
        let transcriptURL = directory.appendingPathComponent(result.transcriptFilename)
        let recordURL = directory.appendingPathComponent("result.json")
        let audioStaging = audioURL.appendingPathExtension("new")
        let transcriptStaging = transcriptURL.appendingPathExtension("new")
        let recordStaging = recordURL.appendingPathExtension("new")
        defer {
            try? fileManager.removeItem(at: audioStaging)
            try? fileManager.removeItem(at: transcriptStaging)
            try? fileManager.removeItem(at: recordStaging)
        }

        try? fileManager.removeItem(at: audioStaging)
        try fileManager.copyItem(at: temporaryAudioURL, to: audioStaging)
        try Data(transcriptText.utf8).write(to: transcriptStaging, options: .atomic)
        try JSONEncoder().encode(result).write(to: recordStaging, options: .atomic)
        try install(staging: audioStaging, destination: audioURL)
        try install(staging: transcriptStaging, destination: transcriptURL)
        try install(staging: recordStaging, destination: recordURL)
        return ResolvedResult(result: result, audioURL: audioURL, transcriptURL: transcriptURL)
    }

    func outputDirectory(videoID: String) -> URL {
        outputRootDirectory.appendingPathComponent(
            LocalDubbingPolicy.safeVideoID(videoID),
            isDirectory: true
        )
    }

    func loadWork(
        videoID: String,
        cacheIdentity: String,
        migrateUnknownLanguage: Bool = false
    ) -> LocalDubbingWorkManifest? {
        let directory = workDirectory(videoID: videoID)
        let url = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(LocalDubbingWorkManifest.self, from: data),
              manifest.isCompatible,
              manifest.videoID == videoID else {
            try? fileManager.removeItem(at: directory)
            return nil
        }
        if manifest.cacheIdentity == cacheIdentity { return manifest }
        guard migrateUnknownLanguage,
              manifest.sourceLanguageDecision?.language == .unknown,
              !manifest.sourceCues.isEmpty,
              manifest.completedSegmentIndices.isEmpty else { return nil }
        var migrated = manifest
        migrated.cacheIdentity = cacheIdentity
        migrated.sourceLanguageDecision = nil
        migrated.translationBypassed = false
        migrated.translationsByIndex = [:]
        return migrated
    }

    func compatibleWork(videoID: String) -> LocalDubbingWorkManifest? {
        let url = workDirectory(videoID: videoID).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(LocalDubbingWorkManifest.self, from: data),
              manifest.isCompatible,
              manifest.videoID == videoID else { return nil }
        return manifest
    }

    func hasResumableWork(videoID: String) -> Bool {
        let url = workDirectory(videoID: videoID).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(LocalDubbingWorkManifest.self, from: data)
        else { return false }
        return manifest.isCompatible && manifest.videoID == videoID
    }

    func saveWork(_ manifest: LocalDubbingWorkManifest) throws {
        let directory = workDirectory(videoID: manifest.videoID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("manifest.json")
        let staging = destination.appendingPathExtension("new")
        try? fileManager.removeItem(at: staging)
        var value = manifest
        value.updatedAt = Date()
        try JSONEncoder().encode(value).write(to: staging, options: .atomic)
        try install(staging: staging, destination: destination)
    }

    func installSegment(
        stagingURL: URL,
        index: Int,
        videoID: String
    ) throws -> URL {
        let directory = segmentDirectory(videoID: videoID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = segmentURL(index: index, videoID: videoID)
        guard ((try? stagingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 44 else {
            throw LocalDubbingFailure.synthesisFailed
        }
        try install(staging: stagingURL, destination: destination)
        return destination
    }

    func segmentURL(index: Int, videoID: String) -> URL {
        segmentDirectory(videoID: videoID)
            .appendingPathComponent(String(format: "segment-%05d.wav", index))
    }

    func validSegmentIndices(videoID: String, total: Int) -> Set<Int> {
        guard total > 0 else { return [] }
        return Set((0..<total).filter { index in
            let url = segmentURL(index: index, videoID: videoID)
            return fileManager.fileExists(atPath: url.path)
                && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 44
        })
    }

    func resetSegments(videoID: String) {
        try? fileManager.removeItem(at: segmentDirectory(videoID: videoID))
    }

    func clearWork(videoID: String) {
        try? fileManager.removeItem(at: workDirectory(videoID: videoID))
    }

    func savePlayback(_ snapshot: LocalDubbingPlaybackSnapshot) throws {
        let directory = outputDirectory(videoID: snapshot.videoID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("playback.json")
        let staging = destination.appendingPathExtension("new")
        try? fileManager.removeItem(at: staging)
        try JSONEncoder().encode(snapshot).write(to: staging, options: .atomic)
        try install(staging: staging, destination: destination)
    }

    func loadPlayback(videoID: String) -> LocalDubbingPlaybackSnapshot? {
        let url = outputDirectory(videoID: videoID).appendingPathComponent("playback.json")
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(LocalDubbingPlaybackSnapshot.self, from: data),
              snapshot.algorithmVersion == LocalDubbingPolicy.algorithmVersion,
              snapshot.videoID == videoID else { return nil }
        return snapshot
    }

    private func workDirectory(videoID: String) -> URL {
        workRootDirectory.appendingPathComponent(
            LocalDubbingPolicy.safeVideoID(videoID),
            isDirectory: true
        )
    }

    private func segmentDirectory(videoID: String) -> URL {
        workDirectory(videoID: videoID).appendingPathComponent("segments", isDirectory: true)
    }

    private func install(staging: URL, destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}
