import XCTest
import AVFoundation
import CoreVideo
@testable import StereoStudio

/// Run with the StereoStudioLocal scheme and the loopback mock server running.
@MainActor
final class LocalIntegrationTests: XCTestCase {
    func testLiveKitDecodesStereoFramesForNativeRenderer() async throws {
        let api = try await localAPI()
        let cap: Capabilities = try await api.request("capabilities")
        guard cap.livekit else { throw XCTSkip("Configure a local LiveKit server for native media integration") }
        let video = StereoVideoSession()
        defer { video.disconnect() }
        video.connect(api: api, capabilities: cap)
        for _ in 0..<200 {
            if video.hasFreshFrame { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(video.connected, video.error ?? video.status)
        XCTAssertTrue(video.hasFreshFrame, video.error ?? video.status)
        let buffer = try XCTUnwrap(video.mailbox.take())
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), cap.eye_width)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), cap.eye_height * 2)
        let textures = try StereoTextures()
        let updated = try await textures.update(buffer)
        XCTAssertTrue(updated)
        XCTAssertNotNil(textures.material)
        video.disconnect()
        XCTAssertFalse(video.hasFreshFrame)
        XCTAssertNil(video.mailbox.take())
    }

    private func localAPI() async throws -> APIClient {
        guard ProcessInfo.processInfo.environment["STEREO_LOCAL_INTEGRATION"] == "1" else {
            throw XCTSkip("Start the mock API, then use the StereoStudioLocal scheme")
        }
        let api = try APIClient(address: "http://127.0.0.1:8765", token: "")
        let cap: Capabilities = try await api.request("capabilities")
        XCTAssertEqual(cap.source, "mock")
        guard cap.source == "mock" else { throw APIError(message: "Local integration requires mock source") }
        return api
    }

    func testNativeDepthMeasurementAndControlRestart() async throws {
        let api = try await localAPI()
        let model = RemoteModel(makeAPI: { _, _ in api })
        defer { model.disconnect() }
        await model.connect()
        for _ in 0..<100 {
            if model.depth.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.connected, model.error ?? "API disconnected")
        let frame = try XCTUnwrap(model.depth.snapshot)
        await model.depth.measure(u: 0.5, v: 0.5, frameID: frame.frame_id)
        let measured = try XCTUnwrap(model.depth.measurement, model.depth.error ?? "No measurement")
        XCTAssertTrue(measured.valid)
        XCTAssertEqual(measured.frame_id, frame.frame_id)
        model.control.simulatedHead = true
        for _ in 0..<2 {
            model.startControl()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(model.control.controlling, model.control.error ?? "Control stopped")
            model.control.stop()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(model.control.controlling)
        }
        model.disconnect()
        XCTAssertNil(model.depth.snapshot)
        XCTAssertFalse(model.connected)
    }

    func testAVFoundationLoadsLoopbackMP4AndHLS() async throws {
        _ = try await localAPI()
        for name in ["demo.mp4", "demo.m3u8"] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8765/media/" + name))
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable, name)
            let duration = try await asset.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 0, name)
        }
    }
}
