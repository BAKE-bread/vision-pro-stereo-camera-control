import Combine
import Foundation
import LiveKit

@MainActor
final class StereoVideoSession: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var hasFreshFrame = false
    @Published private(set) var status = "未连接视频"
    @Published private(set) var error: String?
    private(set) var mailbox = FrameMailbox()
    var onUnavailable: (() -> Void)?
    private var room: Room?
    private var track: VideoTrack?
    private var trackSID: Track.Sid?
    private var descriptor: StreamSession?
    private var connectTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var eyeDimensions = SIMD2<Int>.zero

    func connect(api: APIClient, capabilities: Capabilities) {
        disconnect()
        guard capabilities.livekit else { status = "快照模式；服务器未配置 LiveKit"; return }
        error = nil; busy = true; status = "正在连接视频"
        let attempt = generation
        let currentRoom = Room()
        room = currentRoom
        eyeDimensions = SIMD2(capabilities.eye_width, capabilities.eye_height)
        mailbox = FrameMailbox(width: capabilities.eye_width, eyeHeight: capabilities.eye_height)
        currentRoom.add(delegate: self)
        connectTask = Task {
            do {
                let session: StreamSession = try await api.request("session", body: Data("{}".utf8))
                try Task.checkCancellation()
                guard attempt == generation else { return }
                guard session.layout == "top-bottom", !session.track_name.isEmpty else { throw APIError(message: "视频布局或轨道名称不兼容") }
                descriptor = session
                try await currentRoom.connect(url: session.url, token: session.token)
                try Task.checkCancellation()
                guard attempt == generation else { await currentRoom.disconnect(); return }
                connected = true; busy = false
                status = "已连接，等待双目视频"
                startWatchdog(attempt: attempt)
            } catch {
                guard attempt == generation else { await currentRoom.disconnect(); return }
                let message = error.localizedDescription
                disconnect()
                self.error = message; status = "视频连接失败，可重试；深度仍可使用"
            }
        }
    }

    func disconnect() {
        generation = UUID()
        connectTask?.cancel(); connectTask = nil
        watchdog?.cancel(); watchdog = nil
        clearTrack()
        let oldRoom = room
        room = nil; descriptor = nil
        oldRoom?.remove(delegate: self)
        if let oldRoom { Task { await oldRoom.disconnect() } }
        connected = false; busy = false; error = nil
        status = "未连接视频"
    }

    private func clearTrack() {
        track?.remove(videoRenderer: mailbox)
        track = nil; trackSID = nil
        mailbox.close()
        hasFreshFrame = false
        onUnavailable?()
    }

    private func startWatchdog(attempt: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, attempt == self.generation, !Task.isCancelled else { return }
                let fresh = self.mailbox.isFresh
                self.hasFreshFrame = fresh
                if !fresh { self.onUnavailable?() }
                if let fault = self.mailbox.error { self.error = fault }
                else if fresh { self.error = nil }
                self.status = fresh ? "双目视频已接入" : "等待有效双目画面，跟随已停止"
            }
        }
    }

    func renderingFailed(_ message: String) {
        disconnect()
        error = message; status = "立体渲染失败，请退出后重试视频"
    }
}

extension StereoVideoSession: RoomDelegate {
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            guard self.room === room,
                  self.descriptor?.accepts(publisher: participant.identity?.stringValue, trackName: publication.name) == true,
                  let video = publication.track as? VideoTrack else { return }
            self.track?.remove(videoRenderer: self.mailbox)
            self.mailbox.close()
            self.mailbox = FrameMailbox(width: self.eyeDimensions.x, eyeHeight: self.eyeDimensions.y)
            self.track = video; self.trackSID = publication.sid
            video.add(videoRenderer: self.mailbox)
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            guard self.room === room, publication.sid == self.trackSID else { return }
            self.clearTrack(); self.status = "视频轨道已断开，等待发布者恢复"
        }
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from oldState: ConnectionState) {
        Task { @MainActor in
            guard self.room === room else { return }
            if state == .reconnecting {
                self.connected = false; self.hasFreshFrame = false
                self.mailbox.reset(); self.onUnavailable?()
                self.status = "视频重连中，跟随已停止"
            } else if state == .connected {
                self.connected = true
            }
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard self.room === room else { return }
            self.disconnect()
            self.status = "视频连接断开，可重试；深度仍可使用"
            self.error = error?.localizedDescription
        }
    }
}
