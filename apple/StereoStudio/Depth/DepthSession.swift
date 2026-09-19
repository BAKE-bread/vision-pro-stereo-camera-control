import Combine
import Foundation

struct DepthSelection: Identifiable {
    let id: UUID
    let frame: DepthSnapshot
    let u: Double
    let v: Double
    let server: String
    let selectedAt: Date
    var result: Measurement?
    var error: String?
}

@MainActor
final class DepthSession: ObservableObject {
    @Published private(set) var snapshot: DepthSnapshot?
    @Published private(set) var selection: DepthSelection?
    @Published private(set) var history: [DepthSelection] = []
    @Published private(set) var error: String?
    var displayedSnapshot: DepthSnapshot? { selection?.frame ?? snapshot }
    var measurement: Measurement? { selection?.result }
    var onUnavailable: (() -> Void)?
    private var api: APIClient?
    private var polling: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var measurementID = UUID()
    private var expiresAt: TimeInterval = 0

    func start(api: APIClient) {
        stop()
        self.api = api
        let attempt = generation
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let frame: DepthSnapshot = try await api.request("snapshot")
                    guard let self, attempt == self.generation, !Task.isCancelled else { return }
                    try frame.validate()
                    let expiry = started + 0.75 - Double(frame.age_ms) / 1000
                    guard ProcessInfo.processInfo.systemUptime < expiry else { throw APIError(message: "深度快照已过期") }
                    self.snapshot = frame
                    self.expiresAt = expiry
                    self.error = nil
                } catch {
                    guard let self, attempt == self.generation, !Task.isCancelled else { return }
                    self.invalidate(message: error.localizedDescription)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, attempt == self.generation, !Task.isCancelled else { return }
                if self.snapshot != nil && ProcessInfo.processInfo.systemUptime >= self.expiresAt {
                    self.invalidate(message: "深度快照已过期，等待新数据")
                }
            }
        }
    }

    func stop() {
        generation = UUID(); measurementID = UUID()
        polling?.cancel(); polling = nil
        watchdog?.cancel(); watchdog = nil
        api = nil; snapshot = nil; selection = nil; error = nil
    }

    private func invalidate(message: String) {
        snapshot = nil
        error = message
        onUnavailable?()
    }

    func measure(u: Double, v: Double, frameID: Int) async {
        guard selection == nil, let api, let snapshot, snapshot.frame_id == frameID,
              u.isFinite, v.isFinite, (0...1).contains(u), (0...1).contains(v),
              ProcessInfo.processInfo.systemUptime < expiresAt else { return }
        let attempt = generation
        let requestID = UUID()
        measurementID = requestID
        selection = DepthSelection(id: requestID, frame: snapshot, u: u, v: v,
                                   server: api.base.absoluteString, selectedAt: Date())
        do {
            let data = try JSONSerialization.data(withJSONObject: ["frame_id": frameID, "u": u, "v": v])
            let result: Measurement = try await api.request("depth/measure", body: data)
            guard attempt == generation, requestID == measurementID, !Task.isCancelled else { return }
            guard result.frame_id == frameID else { throw APIError(message: "测量结果与所选帧不一致") }
            selection?.result = result
            if let selection { history.insert(selection, at: 0); history = Array(history.prefix(20)) }
        } catch {
            guard attempt == generation, requestID == measurementID, !Task.isCancelled else { return }
            selection?.error = "测量失败：\(error.localizedDescription)"
        }
    }

    func resumeLive() {
        measurementID = UUID()
        selection = nil
    }

    func review(_ entry: DepthSelection) {
        measurementID = UUID()
        selection = entry
    }
}
