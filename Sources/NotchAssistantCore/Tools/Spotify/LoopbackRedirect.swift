import Foundation
import Network
import Synchronization

/// Receives one OAuth redirect on http://127.0.0.1:<port>/callback, then
/// stops. Bound to the loopback address only, and alive only for the
/// duration of a sign-in.
final class LoopbackRedirect: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.oauth")
    private let redirect = Mutex<CheckedContinuation<URLComponents, any Error>?>(nil)

    /// `port` nil lets the system choose one.
    init(port: UInt16? = nil) throws {
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
                    port.withLock { $0.take()?.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    let inUse = if case .posix(.EADDRINUSE) = error { true } else { false }
                    port.withLock {
                        $0.take()?.resume(throwing: inUse ? ToolError("Another app is using the port Spotify sign-in needs; quit it and try again") : error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to arrive at /callback. Returns its query.
    func callback(timeout: Duration) async throws -> URLComponents {
        defer { listener.cancel() }
        return try await withThrowingTaskGroup(of: URLComponents.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.redirect.withLock { $0 = continuation }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolError("Spotify sign-in timed out")
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
            let isCallback = components?.path == "/callback"
            let body = isCallback
                ? "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>Spotify is connected.</h2><p>You can close this tab.</p></body></html>"
                : "Not found"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let components {
                self?.redirect.withLock { $0.take()?.resume(returning: components) }
            }
        }
    }
}
