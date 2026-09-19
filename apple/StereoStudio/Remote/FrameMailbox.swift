import AVFoundation
import CoreVideo
import LiveKit
import QuartzCore

/// A capacity-one mailbox. SDK callbacks never enqueue unbounded main-actor tasks.
final class FrameMailbox: NSObject, VideoRenderer, @unchecked Sendable {
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var received: CFTimeInterval = 0
    private var accepting = true
    private var fault: String?
    private let width: Int?
    private let eyeHeight: Int?

    init(width: Int? = nil, eyeHeight: Int? = nil) {
        self.width = width; self.eyeHeight = eyeHeight
        super.init()
    }

    nonisolated func render(frame: VideoFrame) {
        guard let buffer = frame.toCVPixelBuffer() else { reject("视频帧无法转换为像素缓冲"); return }
        receive(buffer, rotated: frame.rotation != ._0)
    }

    func receive(_ buffer: CVPixelBuffer, rotated: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard !rotated, w > 0, h > 1, h % 2 == 0,
              width == nil || w == width, eyeHeight == nil || h == eyeHeight! * 2 else {
            pending = nil; received = 0; fault = "视频尺寸或方向与服务器声明的双目布局不一致"
            return
        }
        pending = buffer
        received = CACurrentMediaTime()
        fault = nil
    }
    private func reject(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        pending = nil; received = 0; fault = message
    }
    func take() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        let buffer = pending; pending = nil
        return buffer
    }
    var isFresh: Bool {
        lock.lock(); defer { lock.unlock() }
        return received > 0 && CACurrentMediaTime()-received < 0.75
    }
    var error: String? { lock.lock(); defer { lock.unlock() }; return fault }
    func reset() { lock.lock(); pending = nil; received = 0; fault = nil; accepting = true; lock.unlock() }
    func close() { lock.lock(); pending = nil; received = 0; accepting = false; lock.unlock() }
}
