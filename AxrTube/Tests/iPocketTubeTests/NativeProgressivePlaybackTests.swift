#if os(iOS)
import AVFoundation
import Foundation
import Network
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

@Suite("Native progressive audio integration", .serialized)
struct NativeProgressivePlaybackTests {
    @Test("Native AVPlayer timeline advances before a throttled file finishes")
    func timelineAdvancesBeforeFullTransfer() async throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "progressive-audio", withExtension: "m4a")
        )
        let fixture = try Data(contentsOf: fixtureURL)
        let server = try SlowRangeHTTPServer(media: fixture)
        let url = try server.start()
        defer { server.stop() }

        let asset = DirectAudioPlaybackAssetFactory.make(
            url: url,
            userAgent: "AxrTube-Simulator-Progressive-Test"
        )
        #expect(asset.url.scheme == "http")
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0.5
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.playImmediately(atRate: 1)
        defer { player.pause() }

        // Generous deadline: the throttled server needs several chunks for the
        // first timeline tick; slow CI runners must not make this flaky.
        let deadline = ContinuousClock.now + .seconds(30)
        var fractionAtFirstTimeline: Double?
        while ContinuousClock.now < deadline {
            if item.status == .failed {
                throw item.error ?? NativePlaybackTestError.playerFailed
            }
            if player.currentTime().seconds >= 0.10 {
                fractionAtFirstTimeline = server.uniqueServedFraction
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let served = try #require(fractionAtFirstTimeline)
        #expect(served > 0)
        #expect(served < 0.75)
        #expect(server.uniqueServedBytes < Int64(fixture.count))
    }
}

private enum NativePlaybackTestError: Error {
    case playerFailed
    case listenerFailed
    case listenerTimedOut
}

private final class SlowRangeHTTPServer: @unchecked Sendable {
    private let media: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.axrtube.tests.slow-http")
    private let stateLock = NSLock()
    private var connections: [NWConnection] = []
    private var served = SparseByteRangeIndex()
    private var listenerError: Error?

    init(media: Data) throws {
        self.media = media
        listener = try NWListener(using: .tcp, on: .any)
    }

    var uniqueServedBytes: Int64 {
        stateLock.withLock { served.cachedByteCount }
    }

    var uniqueServedFraction: Double {
        guard !media.isEmpty else { return 0 }
        return Double(uniqueServedBytes) / Double(media.count)
    }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                self.stateLock.withLock { self.listenerError = error }
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success else {
            throw NativePlaybackTestError.listenerTimedOut
        }
        if let listenerError = stateLock.withLock({ listenerError }) {
            throw listenerError
        }
        guard let port = listener.port else {
            throw NativePlaybackTestError.listenerFailed
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/audio.m4a")!
    }

    func stop() {
        listener.cancel()
        let active = stateLock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return connections
        }
        for connection in active { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        stateLock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] content, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var request = accumulated
            if let content { request.append(content) }
            if let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = request[..<headerEnd.upperBound]
                self.respond(to: Data(headerData), on: connection)
            } else if isComplete || request.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, accumulated: request)
            }
        }
    }

    private func respond(to requestData: Data, on connection: NWConnection) {
        let request = String(decoding: requestData, as: UTF8.self)
        let isHead = request.hasPrefix("HEAD ")
        let requested = Self.requestedRange(from: request, total: Int64(media.count))
        let range = requested ?? SparseByteRange(0, Int64(media.count))
        let status = requested == nil ? "200 OK" : "206 Partial Content"
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: audio/mp4",
            "Accept-Ranges: bytes",
            "Content-Length: \(range.count)",
            "Connection: close",
        ]
        if requested != nil {
            headers.append(
                "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(media.count)"
            )
        }
        let payload = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            if isHead {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            } else {
                self.sendBody(on: connection, range: range, cursor: range.lowerBound)
            }
        })
    }

    private func sendBody(
        on connection: NWConnection,
        range: SparseByteRange,
        cursor: Int64
    ) {
        guard cursor < range.upperBound else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            return
        }
        let upper = min(range.upperBound, cursor + 4 * 1024)
        let chunk = media[Int(cursor)..<Int(upper)]
        connection.send(content: Data(chunk), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.stateLock.withLock {
                self.served.insert(SparseByteRange(cursor, upper))
            }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(125)) { [weak self] in
                self?.sendBody(on: connection, range: range, cursor: upper)
            }
        })
    }

    private static func requestedRange(from request: String, total: Int64) -> SparseByteRange? {
        guard let line = request
            .components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
              let marker = line.range(of: "bytes=", options: .caseInsensitive),
              total > 0 else { return nil }
        let bounds = line[marker.upperBound...].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let startText = bounds.first, let start = Int64(startText), start < total else { return nil }
        let requestedEnd = bounds.count > 1 ? Int64(bounds[1]) : nil
        let upper = min(total, (requestedEnd ?? (total - 1)) + 1)
        return SparseByteRange(max(0, start), max(start + 1, upper))
    }
}
#endif
