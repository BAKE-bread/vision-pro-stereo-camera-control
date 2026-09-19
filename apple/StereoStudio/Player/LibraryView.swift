import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var importer = false
    @State private var address = ""
    var body: some View {
        NavigationStack {
            List {
                Section("添加视频") {
                    Button { importer = true } label: { Label("从设备文件导入", systemImage: "square.and.arrow.down") }
                        .disabled(library.importing)
                    if let progress = library.importProgress {
                        ProgressView(value: progress.fraction) {
                            Text("正在导入 \(progress.fileIndex)/\(progress.fileCount)：\(progress.title)")
                        } currentValueLabel: {
                            Text(ByteCountFormatter.string(fromByteCount: progress.copiedBytes, countStyle: .file) + " / " +
                                 ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                        }
                    }
                    HStack {
                        TextField("HTTPS 视频或 HLS 地址", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("播放") { library.addNetwork(address) }.disabled(address.isEmpty)
                    }
                    Text("支持系统可解码的 MOV、MP4 与 HLS。实时双目相机请前往“远程视角”。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("播放列表") {
                    if library.items.isEmpty {
                        ContentUnavailableView("导入第一段视频", systemImage: "film", description: Text("使用系统文件选择器，或添加网络视频地址。"))
                    }
                    ForEach(library.items) { item in
                        HStack {
                            Button { library.play(item) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(item.title, systemImage: item.local ? "film" : "network")
                                    if let seconds = item.resumeSeconds, seconds > 0 {
                                        Text("继续播放 · \(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if (item.resumeSeconds ?? 0) > 0 {
                                Button("从头播放") { library.play(item, resume: false) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let error = library.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("轻量播放器")
            .fileImporter(isPresented: $importer, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importVideos(urls) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }
            .fullScreenCover(isPresented: $library.presenting, onDismiss: { library.pause() }) {
                SystemPlayer(player: library.player)
            }
        }
    }
}

struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}
