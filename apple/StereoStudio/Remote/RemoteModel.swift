import SwiftUI
import Combine

/// Coordinates independent API, depth, media and control sessions.
@MainActor
final class RemoteModel: ObservableObject {
    @AppStorage("cameraServer") var address = "http://127.0.0.1:8765"
    @Published var token = ""
    @Published var error: String?
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published var inSpace = false
    @Published var spaceTransition = false
    let depth = DepthSession()
    let video = StereoVideoSession()
    let control = ControlSession()
    private var api: APIClient?
    private var generation = UUID()
    private var request: Task<Capabilities, Error>?
    private let makeAPI: (String, String) throws -> APIClient

    var status: String { busy ? "正在连接服务器" : (connected ? "服务器已连接" : "未连接") }

    init(makeAPI: @escaping (String, String) throws -> APIClient = { try APIClient(address: $0, token: $1) }) {
        self.makeAPI = makeAPI
        video.onUnavailable = { [weak self] in
            guard let self, !self.control.simulatedHead else { return }
            self.control.stop()
        }
        depth.onUnavailable = { [weak self] in
            guard let self, self.control.simulatedHead else { return }
            self.control.stop()
        }
    }

    func connect() async {
        guard !busy && !connected else { return }
        disconnect()
        let attempt = generation
        busy = true; error = nil
        do {
            let client = try makeAPI(address, token)
            let pending = Task<Capabilities, Error> { try await client.request("capabilities") }
            request = pending
            let cap = try await pending.value
            try Task.checkCancellation()
            guard attempt == generation else { return }
            guard cap.protocol == 1, cap.stereo_layout == "top-bottom",
                  cap.eye_width > 0, cap.eye_height > 0 else { throw APIError(message: "服务器协议、尺寸或双目布局不兼容") }
            api = client; capabilities = cap
            connected = true; busy = false; request = nil
            depth.start(api: client)
            video.connect(api: client, capabilities: cap)
        } catch {
            guard attempt == generation else { return }
            disconnect()
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    /// Invalidate synchronously, before any immersive dismissal or network await.
    func disconnect() {
        generation = UUID()
        request?.cancel(); request = nil
        control.stop(); depth.stop(); video.disconnect()
        connected = false; busy = false; api = nil; capabilities = nil; error = nil
    }

    func retryVideo() {
        guard let api, let capabilities else { return }
        control.stop()
        video.connect(api: api, capabilities: capabilities)
    }

    func startControl() {
        guard connected, capabilities?.head_control == true, let api else { return }
        if control.simulatedHead {
            guard depth.snapshot != nil else { error = "等待有效相机快照后再开始模拟控制。"; return }
        } else {
            guard inSpace, video.hasFreshFrame else { error = "请先进入立体视角，并等待有效双目画面。"; return }
        }
        error = nil
        control.start(api: api)
    }
}
