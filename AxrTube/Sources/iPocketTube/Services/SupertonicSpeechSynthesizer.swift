#if os(iOS)
import CryptoKit
import Foundation
import OnnxRuntimeBindings
import iPocketTubeCore

struct SupertonicPreparedAssets: Sendable {
    let modelDirectory: URL
    let voiceStyleURL: URL
    let byteCount: Int64
}

actor SupertonicModelStore {
    struct Asset: Sendable {
        let relativePath: String
        let byteCount: Int64
        let sha256: String

        var remoteURL: URL {
            URL(string: "https://huggingface.co/Supertone/supertonic-3/resolve/main/\(relativePath)")!
        }
    }

    static let modelLicense = "OpenRAIL-M"
    static let sourceCodeLicense = "MIT"

    private static let assets: [Asset] = [
        Asset(
            relativePath: "onnx/duration_predictor.onnx",
            byteCount: 3_700_147,
            sha256: "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"
        ),
        Asset(
            relativePath: "onnx/text_encoder.onnx",
            byteCount: 36_416_150,
            sha256: "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"
        ),
        Asset(
            relativePath: "onnx/tts.json",
            byteCount: 8_253,
            sha256: "42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09"
        ),
        Asset(
            relativePath: "onnx/unicode_indexer.json",
            byteCount: 277_676,
            sha256: "9bf7346e43883a81f8645c81224f786d43c5b57f3641f6e7671a7d6c493cb24f"
        ),
        Asset(
            relativePath: "onnx/vector_estimator.onnx",
            byteCount: 256_534_781,
            sha256: "883ac868ea0275ef0e991524dc64f16b3c0376efd7c320af6b53f5b780d7c61c"
        ),
        Asset(
            relativePath: "onnx/vocoder.onnx",
            byteCount: 101_424_195,
            sha256: "085de76dd8e8d5836d6ca66826601f615939218f90e519f70ee8a36ed2a4c4ba"
        ),
        Asset(
            relativePath: "voice_styles/M1.json",
            byteCount: 291_748,
            sha256: "e35604687f5d23694b8e91593a93eec0e4eca6c0b02bb8ed69139ab2ea6b0a5b"
        ),
    ]

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let session: URLSession

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.session = session
        let applicationSupport = rootDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootDirectory = applicationSupport
            .appendingPathComponent("AxrTubeDubbing", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Supertonic3", isDirectory: true)
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> SupertonicPreparedAssets {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let totalBytes = Self.assets.reduce(Int64(0)) { $0 + $1.byteCount }
        var completedBytes: Int64 = 0

        for asset in Self.assets {
            try Task.checkCancellation()
            let destination = rootDirectory.appendingPathComponent(asset.relativePath)
            if try isValid(asset: asset, at: destination) {
                completedBytes += asset.byteCount
                progress(Double(completedBytes) / Double(totalBytes))
                continue
            }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let (temporaryURL, response) = try await session.download(from: asset.remoteURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                try? fileManager.removeItem(at: temporaryURL)
                throw LocalDubbingFailure.voiceAssetsUnavailable
            }
            try Task.checkCancellation()
            guard try isValid(asset: asset, at: temporaryURL) else {
                try? fileManager.removeItem(at: temporaryURL)
                throw LocalDubbingFailure.voiceAssetsUnavailable
            }
            let staging = destination.appendingPathExtension("new")
            try? fileManager.removeItem(at: staging)
            try fileManager.moveItem(at: temporaryURL, to: staging)
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
            completedBytes += asset.byteCount
            progress(Double(completedBytes) / Double(totalBytes))
        }

        return SupertonicPreparedAssets(
            modelDirectory: rootDirectory.appendingPathComponent("onnx", isDirectory: true),
            voiceStyleURL: rootDirectory.appendingPathComponent("voice_styles/M1.json"),
            byteCount: totalBytes
        )
    }

    func cachedByteCount() -> Int64 {
        Self.assets.reduce(Int64(0)) { partial, asset in
            let url = rootDirectory.appendingPathComponent(asset.relativePath)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
    }

    private func isValid(asset: Asset, at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1) == asset.byteCount else {
            return false
        }
        return try Self.sha256(of: url) == asset.sha256
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

actor SupertonicSpeechSynthesizer {
    private let modelStore: SupertonicModelStore
    private var environment: ORTEnv?
    private var runtime: TextToSpeech?
    private var voiceStyle: Style?
    private var preparedAssets: SupertonicPreparedAssets?

    init(modelStore: SupertonicModelStore = SupertonicModelStore()) {
        self.modelStore = modelStore
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        if let preparedAssets, runtime != nil, voiceStyle != nil {
            progress(1)
            return preparedAssets.byteCount
        }
        let assets = try await modelStore.prepare(progress: progress)
        try Task.checkCancellation()
        let environment = try ORTEnv(loggingLevel: .warning)
        let runtime = try loadTextToSpeech(assets.modelDirectory.path, false, environment)
        let style = try loadVoiceStyle([assets.voiceStyleURL.path], verbose: false)
        self.environment = environment
        self.runtime = runtime
        self.voiceStyle = style
        self.preparedAssets = assets
        progress(1)
        return assets.byteCount
    }

    func synthesize(text: String, destination: URL, speed: Float = 1.0) async throws -> TimeInterval {
        try Task.checkCancellation()
        guard let runtime, let voiceStyle else {
            throw LocalDubbingFailure.voiceAssetsUnavailable
        }
        let decorated = Self.expressiveRussianText(text)
        let (wav, rawDuration) = try runtime.call(decorated, "ru", voiceStyle, 8, speed: speed)
        try Task.checkCancellation()
        let duration = max(0, Double(rawDuration))
        let sampleCount = min(Int(Double(runtime.sampleRate) * duration), wav.count)
        guard sampleCount > 0 else { throw LocalDubbingFailure.synthesisFailed }
        try writeWavFile(destination.path, Array(wav.prefix(sampleCount)), runtime.sampleRate)
        return duration
    }

    func cleanup() {
        runtime = nil
        voiceStyle = nil
        environment = nil
    }

    func cachedByteCount() async -> Int64 {
        await modelStore.cachedByteCount()
    }

    nonisolated static func expressiveRussianText(_ text: String) -> String {
        let clean = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return clean }
        if clean.hasSuffix("!") || clean.hasSuffix("?") || clean.hasSuffix(".") {
            return clean
        }
        return clean + "."
    }
}
#endif
