import SwiftUI
import RealityKit
import CoreVideo

struct StereoSpace: View {
    @EnvironmentObject var remote: RemoteModel
    @State private var screen = ModelEntity()
    var body: some View {
        RealityView { content in
            // Place once in the room; do not continuously lock a large screen to the head.
            let anchor = AnchorEntity(world: [0, 1.4, -1.8])
            screen.isEnabled = false
            anchor.addChild(screen)
            content.add(anchor)
        }
        .task {
            remote.inSpace = true
            defer {
                screen.isEnabled = false
                remote.control.stop()
            }
            do {
                let textures = try StereoTextures()
                while !Task.isCancelled {
                    let mailbox = remote.video.mailbox
                    if let buffer = mailbox.take() {
                        let changed = try await textures.update(buffer)
                        try Task.checkCancellation()
                        guard mailbox === remote.video.mailbox else { screen.isEnabled = false; continue }
                        if changed, let material = textures.material {
                            let ratio = Float(CVPixelBufferGetHeight(buffer)/2)/Float(CVPixelBufferGetWidth(buffer))
                            screen.model = ModelComponent(mesh: .generatePlane(width: 1.2, height: 1.2*ratio), materials: [material])
                        }
                    }
                    screen.isEnabled = remote.video.mailbox.isFresh && screen.model != nil
                    if !screen.isEnabled && !remote.control.simulatedHead { remote.control.stop() }
                    try await Task.sleep(for: .milliseconds(33))
                }
            } catch {
                if !Task.isCancelled { remote.video.renderingFailed("立体渲染失败：\(error.localizedDescription)") }
            }
        }
        .onDisappear {
            remote.inSpace = false
            remote.spaceTransition = false
            screen.isEnabled = false
            remote.control.stop()
        }
    }
}
