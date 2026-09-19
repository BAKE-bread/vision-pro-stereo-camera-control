import ARKit
import QuartzCore
import simd

@MainActor
protocol HeadTrackingSession: AnyObject {
    func start() async throws
    func stop()
    func transform() -> simd_float4x4?
}

@MainActor
private final class ARHeadTrackingSession: HeadTrackingSession {
    private let session = ARKitSession()
    private let provider = WorldTrackingProvider()
    private var stopped = false

    func start() async throws {
        guard WorldTrackingProvider.isSupported else { throw APIError(message: "当前环境不支持头部追踪；模拟器请使用模拟角度。") }
        // World tracking does not require world-sensing permission. Request only
        // the provider's declared authorizations, rather than gating device pose
        // on unrelated plane/mesh access.
        let required = WorldTrackingProvider.requiredAuthorizations
        if !required.isEmpty {
            let authorization = await session.requestAuthorization(for: required)
            guard required.allSatisfy({ authorization[$0] == .allowed }) else {
                throw APIError(message: "系统未允许头部追踪所需的权限。")
            }
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try await session.run([provider])
        guard !stopped else { session.stop(); throw CancellationError() }
    }

    func stop() { stopped = true; session.stop() }

    func transform() -> simd_float4x4? {
        guard !stopped, provider.state == .running,
              let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked else { return nil }
        return anchor.originFromAnchorTransform
    }
}

@MainActor
final class HeadPose {
    private let makeSession: @MainActor () -> any HeadTrackingSession
    private var session: (any HeadTrackingSession)?
    private var generation = UUID()
    private var baseline: simd_float4x4?
    private var previous: SIMD2<Float>?
    private var filtered = SIMD2<Float>.zero

    init(makeSession: @escaping @MainActor () -> any HeadTrackingSession = { ARHeadTrackingSession() }) {
        self.makeSession = makeSession
    }

    func start() async throws {
        stop()
        let attempt = generation
        let fresh = makeSession()
        session = fresh
        do {
            try await fresh.start()
            try Task.checkCancellation()
            guard attempt == generation else { throw CancellationError() }
            recenter()
        } catch {
            fresh.stop()
            if attempt == generation { session = nil }
            throw error
        }
    }
    func stop() {
        generation = UUID()
        session?.stop(); session = nil
        recenter()
    }
    func recenter() { baseline = nil; previous = nil; filtered = .zero }

    func angles() -> SIMD2<Float>? {
        guard let current = session?.transform() else { return nil }
        if baseline == nil { baseline = current }
        guard let baseline else { return nil }
        let relative = simd_inverse(baseline) * current
        // ARKit forward=-Z. Map to server yaw right-positive, pitch up-positive.
        let forward = -SIMD3<Float>(relative.columns.2.x, relative.columns.2.y, relative.columns.2.z)
        let raw = SIMD2<Float>(atan2(forward.x, -forward.z), atan2(forward.y, hypot(forward.x, forward.z))) * (180 / .pi)
        guard raw.x.isFinite, raw.y.isFinite else { return nil }
        if let previous, simd_length(raw-previous) > 35 { return nil }
        previous = raw
        filtered += (raw-filtered)*0.25
        return filtered
    }
}
