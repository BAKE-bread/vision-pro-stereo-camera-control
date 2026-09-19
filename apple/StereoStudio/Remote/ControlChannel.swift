import Foundation

@MainActor
protocol ControlChannel: AnyObject {
    func open()
    func send(_ payload: [String: Any]) async throws
    func receive() async throws -> [String: Any]
    func close()
}

@MainActor
final class WebSocketControlChannel: ControlChannel {
    private let socket: URLSessionWebSocketTask
    private var receiveID = UUID()
    private var timedOut: UUID?

    init(api: APIClient) throws {
        socket = api.session.webSocketTask(with: try api.controlURL())
    }

    func open() { socket.resume() }

    func send(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await withTimeout { try await self.socket.send(.string(String(decoding: data, as: UTF8.self))) }
    }

    func receive() async throws -> [String: Any] {
        let message = try await withTimeout { try await self.socket.receive() }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw APIError(message: "未知控制消息")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError(message: "无效控制响应") }
        return object
    }

    private func withTimeout<T: Sendable>(_ operation: @MainActor () async throws -> T) async throws -> T {
        let attempt = UUID()
        receiveID = attempt; timedOut = nil
        // Server leases last one second; never keep a stalled client marked active.
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            guard let self, !Task.isCancelled, self.receiveID == attempt else { return }
            self.timedOut = attempt
            self.socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        do {
            return try await operation()
        } catch {
            if timedOut == attempt { throw APIError(message: "控制响应超时，请检查连接后重新开始") }
            throw error
        }
    }

    func close() {
        receiveID = UUID()
        socket.cancel(with: .goingAway, reason: nil)
    }
}
