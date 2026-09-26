import Foundation
import Network
import Synchronization

/// Receives one OAuth redirect on http://127.0.0.1:<port><path>, then
/// stops. Bound to the loopback address only, and alive only for the
/// duration of a sign-in.
final class LoopbackRedirect: Sendable {
    private let listener: NWListener
    /// The same port on IPv6 loopback, for browsers that resolve
    /// "localhost" to ::1 first (Microsoft's redirect is http://localhost).
    private let ipv6 = Mutex<NWListener?>(nil)
    private let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.oauth")
    private let redirect = Mutex<CheckedContinuation<URLComponents, any Error>?>(nil)
    private let service: String
    private let path: String

    /// `port` nil lets the system choose one. `service` names the sign-in in
    /// messages and on the page the browser shows.
    init(port: UInt16? = nil, service: String = "Spotify", path: String = "/callback") throws {
        self.service = service
        self.path = path
        let parameters = NWParameters.tcp
        let endpointPort = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the port the system assigned.
    func start() async throws -> UInt16 {
        let port = Mutex<CheckedContinuation<UInt16, any Error>?>(nil)
        return try await withCheckedThrowingContinuation { continuation in
            port.withLock { $0 = continuation }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    self.listenOnIPv6(port: listener.port)
                    port.withLock { $0.take()?.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    let inUse = if case .posix(.EADDRINUSE) = error { true } else { false }
                    port.withLock {
                        $0.take()?.resume(throwing: inUse ? ToolError("Another app is using the port \(self.service) sign-in needs; quit it and try again") : error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Best effort: without it, IPv4 loopback still works.
    private func listenOnIPv6(port: NWEndpoint.Port?) {
        guard let port else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: port)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        ipv6.withLock { $0 = listener }
    }

    /// Waits for the browser to arrive at the callback path. Returns its query.
    func callback(timeout: Duration) async throws -> URLComponents {
        defer {
            listener.cancel()
            ipv6.withLock { $0?.cancel() }
        }
        return try await withThrowingTaskGroup(of: URLComponents.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.redirect.withLock { $0 = continuation }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolError("\(self.service) sign-in timed out")
            }
            defer {
                group.cancelAll()
                redirect.withLock { $0.take()?.resume(throwing: CancellationError()) }
            }
            return try await group.next()!
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            // Request line: "GET /callback?code=…&state=… HTTP/1.1"
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            let components = parts.count >= 2 ? URLComponents(string: "http://127.0.0.1" + parts[1]) : nil
            guard let self else { return }
            let isCallback = components?.path == self.path || (self.path == "/" && components?.path == "")
            let body = isCallback
                ? "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>\(self.service) is connected.</h2><p>You can close this tab.</p></body></html>"
                : "Not found"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let components {
                self.redirect.withLock { $0.take()?.resume(returning: components) }
            }
        }
    }
}
