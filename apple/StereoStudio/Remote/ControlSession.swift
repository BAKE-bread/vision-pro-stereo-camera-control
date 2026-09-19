import Combine
import Foundation

@MainActor
final class ControlSession: ObservableObject {
    @Published private(set) var controlling = false
    @Published private(set) var error: String?
    @Published private(set) var status = "未控制"
    @Published var simulatedHead = false
    @Published var yaw: Double = 0
    @Published var pitch: Double = 0
    private let head: HeadPose
    private var channel: (any ControlChannel)?
    private let makeChannel: @MainActor (APIClient) throws -> any ControlChannel
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(head: HeadPose? = nil, makeChannel: (@MainActor (APIClient) throws -> any ControlChannel)? = nil) {
        self.head = head ?? HeadPose()
        self.makeChannel = makeChannel ?? { try WebSocketControlChannel(api: $0) }
    }

    func start(api: APIClient) {
        guard !controlling else { return }
        stop()
        error = nil; controlling = true; status = "正在申请控制权"
        let attempt = generation
        let simulated = simulatedHead
        let origin = SIMD2(yaw, pitch)
        task = Task {
            do {
                if !simulated { try await head.start() }
                try Task.checkCancellation()
                guard attempt == generation else { return }
                let ws = try makeChannel(api)
                channel = ws; ws.open()
                try await ws.send(["token": api.token])
                let hello = try await receive(ws)
                try Task.checkCancellation()
                guard attempt == generation else { return }
                guard hello["type"] as? String == "lease",
                      let initialYaw = hello["yaw_deg"] as? Double,
                      let initialPitch = hello["pitch_deg"] as? Double,
                      initialYaw.isFinite, initialPitch.isFinite else { throw APIError(message: "无效控制租约") }
                let center = SIMD2(initialYaw, initialPitch)
                status = simulated ? "模拟角度控制中" : "头部跟随中"
                var sequence = 0
                var lastPose = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled && attempt == generation {
                    let angles: SIMD2<Double>
                    if simulated { angles = SIMD2(yaw, pitch) - origin }
                    else {
                        guard let pose = head.angles() else {
                            if ProcessInfo.processInfo.systemUptime - lastPose > 0.5 { throw APIError(message: "头部追踪中断，请重新开始跟随") }
                            try await Task.sleep(for: .milliseconds(50)); continue
                        }
                        lastPose = ProcessInfo.processInfo.systemUptime
                        angles = SIMD2(Double(pose.x), Double(pose.y))
                    }
                    let target = center + angles
                    let payload: [String: Any] = ["sequence": sequence, "yaw_deg": target.x, "pitch_deg": target.y]
                    try await ws.send(payload)
                    let ack = try await receive(ws)
                    guard ack["type"] as? String == "ack", ack["sequence"] as? Int == sequence, ack["active"] as? Bool == true else {
                        throw APIError(message: "控制确认无效或租约已失效")
                    }
                    sequence += 1
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                if !Task.isCancelled && attempt == generation { self.error = "控制已停止：\(error.localizedDescription)" }
            }
            if attempt == generation { stop() }
        }
    }

    private func receive(_ ws: any ControlChannel) async throws -> [String: Any] {
        let object = try await ws.receive()
        if let error = object["error"] as? String { throw APIError(message: error) }
        return object
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        channel?.close(); channel = nil
        head.stop(); controlling = false; status = "控制已停止"
    }
}
