import SwiftUI

@main
struct StereoStudioApp: App {
    @StateObject private var remote = RemoteModel()
    @StateObject private var library = LibraryModel()
    var body: some Scene {
        WindowGroup {
            StudioView().environmentObject(remote).environmentObject(library)
                .environmentObject(remote.depth).environmentObject(remote.video).environmentObject(remote.control)
        }
        .defaultSize(width: 1000, height: 720)
        ImmersiveSpace(id: "StereoCamera") {
            StereoSpace().environmentObject(remote)
        }.immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

struct StudioView: View {
    @EnvironmentObject var remote: RemoteModel
    @EnvironmentObject var library: LibraryModel
    @Environment(\.scenePhase) var phase
    @Environment(\.dismissImmersiveSpace) var dismissSpace
    var body: some View {
        TabView {
            LibraryView().tabItem { Label("播放器", systemImage: "play.rectangle") }
            RemoteView().tabItem { Label("远程视角", systemImage: "video") }
            DepthView().tabItem { Label("深度工具", systemImage: "ruler") }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .active {
                library.pause()
                remote.control.stop()
                // A transient inactive phase may accompany immersive presentation.
                if newPhase == .background {
                    remote.disconnect()
                    Task { if remote.inSpace { await dismissSpace() } }
                }
            }
        }
    }
}
