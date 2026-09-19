import XCTest
import CoreVideo
import simd
import Metal
import ARKit
@testable import StereoStudio

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var response: ((URLRequest) -> (Int, Data, TimeInterval))?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.response else { return }
        let (status, data, delay) = response(request)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let reply = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}

@MainActor
final class SessionTests: XCTestCase {
    private let capabilities = Data("""
        {"protocol":1,"source":"mock","stereo_layout":"top-bottom","eye_width":8,"eye_height":4,
         "head_control":true,"livekit":true,"video_status":"connecting"}
        """.utf8)
    private let snapshot = Data("""
        {"protocol":1,"unit":"m","alignment":"left","frame_id":1,"source":"mock","captured_at_ms":1234,
         "age_ms":0,"width":8,"height":4,"preview_jpeg":"","depth_width":1,"depth_height":1,
         "depth_m":[2.0],"near_m":2.0,"near_warning":false,"valid_fraction":1.0}
        """.utf8)

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testDisconnectDuringCapabilitiesCannotRestoreConnection() async throws {
        let entered = expectation(description: "capabilities requested")
        let cap = capabilities
        StubURLProtocol.response = { _ in entered.fulfill(); return (200, cap, 1) }
        let session = makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.response = nil }
        let model = RemoteModel(makeAPI: { try APIClient(address: $0, token: $1, session: session) })
        let connecting = Task { await model.connect() }
        await fulfillment(of: [entered], timeout: 2)
        model.disconnect()
        await connecting.value
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.capabilities)
        XCTAssertNil(model.depth.snapshot)
        XCTAssertFalse(model.video.connected)
    }

    func testMediaFailureLeavesDepthAndAPIAvailable() async throws {
        let cap = capabilities, frame = snapshot
        StubURLProtocol.response = { request in
            switch request.url!.lastPathComponent {
            case "capabilities": return (200, cap, 0)
            case "snapshot": return (200, frame, 0)
            default: return (503, Data("{\"detail\":\"media offline\"}".utf8), 0)
            }
        }
        let session = makeSession()
        let model = RemoteModel(makeAPI: { try APIClient(address: $0, token: $1, session: session) })
        defer { model.disconnect(); session.invalidateAndCancel(); StubURLProtocol.response = nil }
        await model.connect()
        for _ in 0..<100 {
            if model.depth.snapshot != nil && model.video.error != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.connected)
        XCTAssertNotNil(model.depth.snapshot)
        XCTAssertFalse(model.video.connected)
        XCTAssertFalse(model.video.busy)
        XCTAssertNotNil(model.video.error)
    }

    func testSlowHTTPDoesNotLeaveStaleDepthVisible() async throws {
        let frame = snapshot
        var requests = 0
        StubURLProtocol.response = { _ in
            requests += 1
            return (200, frame, requests == 1 ? 0 : 3)
        }
        let session = makeSession()
        let depth = DepthSession()
        defer { depth.stop(); session.invalidateAndCancel(); StubURLProtocol.response = nil }
        depth.start(api: try APIClient(address: "http://depth.test", token: "", session: session))
        for _ in 0..<50 {
            if depth.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(depth.snapshot)
        try await Task.sleep(for: .milliseconds(950))
        XCTAssertNil(depth.snapshot)
        XCTAssertNil(depth.measurement)
        XCTAssertNotNil(depth.error)
    }

    func testTrackFilterRequiresPublisherNameAndLayout() throws {
        let stream = StreamSession(url: "ws://test", token: "", track_name: "stereo", layout: "top-bottom", publisher_identity: "stereo-camera")
        XCTAssertTrue(stream.accepts(publisher: "stereo-camera", trackName: "stereo"))
        XCTAssertFalse(stream.accepts(publisher: "viewer", trackName: "stereo"))
        XCTAssertFalse(stream.accepts(publisher: "stereo-camera", trackName: "screen"))
        XCTAssertFalse(stream.accepts(publisher: nil, trackName: "stereo"))
    }

    func testInvalidDepthMetadataIsRejected() throws {
        let valid = try JSONDecoder().decode(DepthSnapshot.self, from: snapshot)
        XCTAssertNoThrow(try valid.validate())
        for (key, value) in [("unit", "mm"), ("alignment", "right"), ("age_ms", 800), ("depth_width", 2)] as [(String, Any)] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
            json[key] = value
            let invalid = try JSONDecoder().decode(DepthSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try invalid.validate())
        }
    }

    func testURLValidationAndWebSocketScheme() throws {
        XCTAssertThrowsError(try APIClient(address: "https://host?token=secret", token: ""))
        XCTAssertThrowsError(try APIClient(address: "ftp://host", token: ""))
        let api = try APIClient(address: "https://host/prefix", token: "secret")
        XCTAssertEqual(try api.controlURL().absoluteString, "wss://host/prefix/api/control")
    }

    func testMeasurementKeepsItsOwnSnapshotWhileLiveFramesAdvance() async throws {
        let frame = snapshot
        var frameID = 0
        var selectedID = 0
        StubURLProtocol.response = { request in
            if request.url!.lastPathComponent == "measure" {
                let result = "{\"frame_id\":\(selectedID),\"valid\":true,\"axial_m\":2,\"range_m\":2}"
                return (200, Data(result.utf8), 0)
            }
            frameID += 1
            var json = try! JSONSerialization.jsonObject(with: frame) as! [String: Any]
            json["frame_id"] = frameID
            return (200, try! JSONSerialization.data(withJSONObject: json), 0)
        }
        let session = makeSession()
        let depth = DepthSession()
        defer { depth.stop(); session.invalidateAndCancel(); StubURLProtocol.response = nil }
        depth.start(api: try APIClient(address: "http://depth.test", token: "", session: session))
        for _ in 0..<50 {
            if depth.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        selectedID = try XCTUnwrap(depth.snapshot).frame_id
        await depth.measure(u: 0.25, v: 0.75, frameID: selectedID)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(depth.displayedSnapshot?.frame_id, selectedID)
        XCTAssertGreaterThan(try XCTUnwrap(depth.snapshot).frame_id, selectedID)
        XCTAssertEqual(depth.selection?.u, 0.25)
        XCTAssertEqual(depth.selection?.v, 0.75)
        XCTAssertEqual(depth.history.count, 1)
        XCTAssertEqual(depth.history.first?.result?.frame_id, selectedID)
        depth.resumeLive()
        XCTAssertNil(depth.selection)
        XCTAssertEqual(depth.displayedSnapshot?.frame_id, depth.snapshot?.frame_id)
    }

    func testDismissedMeasurementCannotReappearFromLateResponse() async throws {
        let frame = snapshot
        StubURLProtocol.response = { request in
            if request.url!.lastPathComponent == "measure" {
                return (200, Data("{\"frame_id\":1,\"valid\":true,\"axial_m\":2,\"range_m\":2}".utf8), 0.2)
            }
            return (200, frame, 0)
        }
        let session = makeSession()
        let depth = DepthSession()
        defer { depth.stop(); session.invalidateAndCancel(); StubURLProtocol.response = nil }
        depth.start(api: try APIClient(address: "http://depth.test", token: "", session: session))
        for _ in 0..<50 {
            if depth.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let measuring = Task { await depth.measure(u: 0.5, v: 0.5, frameID: 1) }
        for _ in 0..<50 {
            if depth.selection != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(depth.selection)
        depth.resumeLive()
        await measuring.value
        XCTAssertNil(depth.selection)
        XCTAssertTrue(depth.history.isEmpty)
    }
}

@MainActor
private final class FakeControlChannel: ControlChannel {
    var closed = false
    var sent: [[String: Any]] = []
    var delayLease = false
    var invalidAck = false
    var pendingLease: CheckedContinuation<[String: Any], Never>?
    private var receivedLease = false
    func open() {}
    func send(_ payload: [String: Any]) async throws { sent.append(payload) }
    func receive() async throws -> [String: Any] {
        if !receivedLease {
            receivedLease = true
            if delayLease { return await withCheckedContinuation { pendingLease = $0 } }
            return ["type": "lease", "yaw_deg": 0.0, "pitch_deg": 0.0]
        }
        return ["type": "ack", "sequence": invalidAck ? -1 : (sent.last?["sequence"] as? Int ?? -1), "active": true]
    }
    func close() { closed = true }
}

@MainActor
final class ControlSessionTests: XCTestCase {
    func testLateOldLeaseDoesNotStopReplacementControlSession() async throws {
        let old = FakeControlChannel(); old.delayLease = true
        let current = FakeControlChannel()
        var attempts = 0
        let control = ControlSession(makeChannel: { _ in attempts += 1; return attempts == 1 ? old : current })
        control.simulatedHead = true
        let api = try APIClient(address: "http://control.test", token: "")
        control.start(api: api)
        for _ in 0..<50 {
            if old.pendingLease != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(old.pendingLease)
        control.stop()
        control.start(api: api)
        old.pendingLease?.resume(returning: ["type": "lease", "yaw_deg": 90.0, "pitch_deg": 0.0])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(old.closed)
        XCTAssertTrue(control.controlling)
        XCTAssertFalse(current.closed)
        XCTAssertNil(control.error)
        XCTAssertEqual(current.sent.last?["yaw_deg"] as? Double, 0)
        control.stop()
        XCTAssertTrue(current.closed)
    }

    func testInvalidAckStopsAndClosesChannel() async throws {
        let channel = FakeControlChannel(); channel.invalidAck = true
        let control = ControlSession(makeChannel: { _ in channel })
        control.simulatedHead = true
        control.start(api: try APIClient(address: "http://control.test", token: ""))
        for _ in 0..<50 {
            if !control.controlling { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(control.controlling)
        XCTAssertTrue(channel.closed)
        XCTAssertNotNil(control.error)
    }
}

@MainActor
private final class FakeTracking: HeadTrackingSession {
    var pose = matrix_identity_float4x4
    var stopped = false
    var pending: CheckedContinuation<Void, Never>?
    var delay = false
    var onStart: (() -> Void)?
    func start() async throws {
        onStart?()
        if delay { await withCheckedContinuation { pending = $0 } }
    }
    func stop() { stopped = true }
    func transform() -> simd_float4x4? { stopped ? nil : pose }
}

@MainActor
final class HeadPoseTests: XCTestCase {
    func testWorldTrackingDoesNotRequireWorldSensingPermission() {
        XCTAssertFalse(WorldTrackingProvider.requiredAuthorizations.contains(.worldSensing))
    }

    func testRelativeHeadRotationUsesRightPositiveYawAndUpPositivePitch() async throws {
        let session = FakeTracking()
        let baseline = simd_float4x4(simd_quatf(angle: 1.1, axis: [0, 1, 0]))
        session.pose = baseline
        let head = HeadPose { session }
        try await head.start()
        defer { head.stop() }
        let zero = try XCTUnwrap(head.angles())
        XCTAssertEqual(zero.x, 0, accuracy: 0.00001)
        XCTAssertEqual(zero.y, 0, accuracy: 0.00001)
        let yaw = simd_float4x4(simd_quatf(angle: -20 * .pi / 180, axis: [0, 1, 0]))
        let pitch = simd_float4x4(simd_quatf(angle: 10 * .pi / 180, axis: [1, 0, 0]))
        session.pose = baseline * yaw * pitch
        session.pose.columns.3 = SIMD4<Float>(2, 3, 4, 1)
        let angle = try XCTUnwrap(head.angles())
        // The first sample applies the 0.25 smoothing factor to a 20° / 10° turn.
        XCTAssertEqual(angle.x, 5, accuracy: 0.001)
        XCTAssertEqual(angle.y, 2.5, accuracy: 0.001)
        session.pose = baseline * simd_float4x4(simd_quatf(angle: -1.5, axis: [0, 1, 0]))
        XCTAssertNil(head.angles(), "large tracking discontinuities must not command the gimbal")
    }

    func testEveryRestartCreatesNewProvider() async throws {
        var sessions: [FakeTracking] = []
        let head = HeadPose {
            let session = FakeTracking(); sessions.append(session); return session
        }
        try await head.start()
        XCTAssertNotNil(head.angles())
        head.stop()
        XCTAssertNil(head.angles())
        try await head.start()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions[0].stopped)
        XCTAssertFalse(sessions[1].stopped)
        XCTAssertEqual(head.angles(), .zero)
        head.stop()
    }

    func testStopDuringAuthorizationCannotReviveOldProvider() async throws {
        let entered = expectation(description: "tracking start")
        let session = FakeTracking(); session.delay = true; session.onStart = { entered.fulfill() }
        let head = HeadPose { session }
        let starting = Task { try await head.start() }
        await fulfillment(of: [entered], timeout: 2)
        head.stop()
        session.pending?.resume()
        do { try await starting.value; XCTFail("stopped start must be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(head.angles())
    }
}

@MainActor
final class RenderingTests: XCTestCase {
    private func buffer(width: Int = 8, height: Int = 8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testInvalidFramesAndLateCallbacksCannotRestoreClosedMailbox() throws {
        let mailbox = FrameMailbox(width: 8, eyeHeight: 4)
        mailbox.receive(try buffer())
        XCTAssertTrue(mailbox.isFresh)
        XCTAssertNotNil(mailbox.take())
        mailbox.receive(try buffer(width: 10))
        XCTAssertFalse(mailbox.isFresh)
        XCTAssertNotNil(mailbox.error)
        XCTAssertNil(mailbox.take())
        mailbox.receive(try buffer(), rotated: true)
        XCTAssertFalse(mailbox.isFresh)
        mailbox.close()
        mailbox.receive(try buffer())
        XCTAssertFalse(mailbox.isFresh)
        XCTAssertNil(mailbox.take())
    }

    func testStereoMaterialLoadsAndBindsBothTextures() async throws {
        let textures = try StereoTextures()
        let source = try buffer()
        CVPixelBufferLockBaseAddress(source, [])
        let bytes = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(source)
        for y in 0..<8 {
            for x in 0..<8 {
                let p = y * rowBytes + x * 4
                bytes[p] = y >= 4 ? 255 : 0 // bottom/right = blue
                bytes[p + 1] = 0
                bytes[p + 2] = y < 4 ? 255 : 0 // top/left = red
                bytes[p + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let first = try await textures.update(source)
        XCTAssertTrue(first)
        XCTAssertNotNil(textures.material)
        let left = try await readFirstPixel(XCTUnwrap(textures.left).read())
        let right = try await readFirstPixel(XCTUnwrap(textures.right).read())
        XCTAssertGreaterThan(left[0], 0.9, "left eye must contain top red image")
        XCTAssertLessThan(left[2], 0.1)
        XCTAssertLessThan(right[0], 0.1)
        XCTAssertGreaterThan(right[2], 0.9, "right eye must contain bottom blue image")
        let unchanged = try await textures.update(source)
        XCTAssertFalse(unchanged)
    }

    private func readFirstPixel(_ texture: any MTLTexture) async throws -> [Float] {
        let device = texture.device
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let target = try XCTUnwrap(device.makeBuffer(length: 256, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: 1, height: 1, depth: 1), to: target,
                  destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        XCTAssertEqual(command.status, .completed)
        let pixel = target.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<4).map { Float(Float16(bitPattern: pixel[$0])) }
    }
}
