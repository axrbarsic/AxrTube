import Foundation
import Network
import os

/// Minimal HTTP/1.1 server bound to 127.0.0.1 for the player. GET/HEAD
/// only, keep-alive, single `Range: bytes=a-b` support. Loopback-only, so
/// it is unreachable from the network and needs no local-network prompt.
public final class LoopbackHTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
    }

    public struct Response: Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data

        public init(status: Int, contentType: String = "application/octet-stream", body: Data = Data()) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    private let handler: Handler
    private let queue = DispatchQueue(label: "axrtube.loopback-http", qos: .userInitiated)
    private let log = Logger(subsystem: "com.void.ipockettube.app", category: "StreamCache")
    private let lock = OSAllocatedUnfairLock<(listener: NWListener?, port: UInt16?)>(initialState: (nil, nil))
    /// Port of the previous listener: a restart reuses it so URLs already
    /// handed to the player keep working.
    private let lastPort = OSAllocatedUnfairLock<UInt16?>(initialState: nil)

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var port: UInt16? { lock.withLock { $0.port } }

    /// Starts (or returns the running) listener's port.
    public func start() async -> UInt16? {
        if let port { return port }
        if let previous = lastPort.withLock({ $0 }), let port = await listen(on: previous) { return port }
        return await listen(on: nil)
    }

    /// Checks that the listener still accepts connections (iOS can reclaim
    /// it while the app is suspended) and restarts it on the same port.
    @discardableResult
    public func ensureAlive() async -> UInt16? {
        guard let port else { return await start() }
        if await Self.accepts(port: port) { return port }
        log.notice("[stream-cache] listener on \(port) is dead — restarting")
        let old = lock.withLock { state -> NWListener? in
            defer { state = (nil, nil) }
            return state.listener
        }
        old?.cancel()
        return await start()
    }

    private static func accepts(port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { value in
                if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finish(false) }
        }
    }

    private func listen(on fixedPort: UInt16?) async -> UInt16? {
        let params = NWParameters.tcp
        let nwPort = fixedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return nil }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let port: UInt16? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak self] state in
                let finish: (UInt16?) -> Void = { value in
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(returning: value) }
                }
                switch state {
                case .ready: finish(listener.port?.rawValue)
                case .failed(let error):
                    self?.log.error("[stream-cache] listener failed: \(error.localizedDescription)")
                    self?.lock.withLock { $0 = (nil, nil) }
                    finish(nil)
                case .cancelled:
                    self?.lock.withLock { $0 = (nil, nil) }
                    finish(nil)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let port else { listener.cancel(); return nil }
        lock.withLock { $0 = (listener, port) }
        lastPort.withLock { $0 = port }
        return port
    }

    // MARK: Connections

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer.subdata(in: buffer.startIndex..<end.lowerBound)
                let rest = buffer.subdata(in: end.upperBound..<buffer.endIndex)
                guard let request = Self.parse(head) else { connection.cancel(); return }
                Task {
                    let response = await self.handler(request)
                    self.send(response, for: request, on: connection) {
                        self.receive(on: connection, buffer: rest)
                    }
                }
                return
            }
            if isComplete || error != nil || buffer.count > 64 * 1024 { connection.cancel(); return }
            self.receive(on: connection, buffer: buffer)
        }
    }

    static func parse(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers)
    }

    /// `bytes=a-b`, `bytes=a-`, `bytes=-n` → closed range within `length`.
    static func byteRange(_ header: String?, length: Int) -> ClosedRange<Int>? {
        guard let header, header.hasPrefix("bytes="), length > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard bounds.count == 2 else { return nil }
        switch (bounds[0], bounds[1]) {
        case let (a?, b?) where a <= b && a < length: return a...min(b, length - 1)
        case let (a?, nil) where a < length: return a...(length - 1)
        case let (nil, n?) where n > 0: return max(0, length - n)...(length - 1)
        default: return nil
        }
    }

    private func send(_ response: Response, for request: Request, on connection: NWConnection, then next: @escaping @Sendable () -> Void) {
        var status = response.status
        var body = response.body
        var extra = ""
        if status == 200, let range = Self.byteRange(request.headers["range"], length: body.count) {
            extra = "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(body.count)\r\n"
            body = body.subdata(in: range.lowerBound..<(range.upperBound + 1))
            status = 206
        }
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 502: "Bad Gateway"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(response.contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + extra
            + "Cache-Control: no-store\r\n"
            + "Connection: keep-alive\r\n\r\n"
        var packet = Data(head.utf8)
        if request.method != "HEAD" { packet.append(body) }
        connection.send(content: packet, completion: .contentProcessed { error in
            if error != nil { connection.cancel() } else { next() }
        })
    }
}
