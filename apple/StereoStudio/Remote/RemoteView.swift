import SwiftUI
import UIKit

struct RemoteView: View {
    @EnvironmentObject var remote: RemoteModel
    @EnvironmentObject var depth: DepthSession
    @EnvironmentObject var video: StereoVideoSession
    @EnvironmentObject var control: ControlSession
    @Environment(\.openImmersiveSpace) var openSpace
    @Environment(\.dismissImmersiveSpace) var dismissSpace
    var body: some View {
        NavigationStack {
            Form {
                Section("相机服务器") {
                    TextField("http://服务器地址:8765", text: $remote.address).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(remote.connected || remote.busy)
                    SecureField("访问令牌", text: $remote.token).disabled(remote.connected || remote.busy)
                    HStack {
                        Button(remote.busy ? "连接中…" : "连接") { Task { await remote.connect() } }.disabled(remote.busy || remote.connected)
                        Button(remote.busy ? "取消连接" : "断开") {
                            remote.disconnect()
                            Task { if remote.inSpace { await dismissSpace() } }
                        }.disabled(!remote.connected && !remote.busy)
                        Text(remote.status).foregroundStyle(.secondary)
                    }
                }
                Section("立体视角") {
                    Text(video.status).foregroundStyle(.secondary)
                    if remote.connected && remote.capabilities?.livekit == true {
                        Button("重试视频连接") {
                            Task {
                                if remote.inSpace { await dismissSpace() }
                                remote.retryVideo()
                            }
                        }.disabled(video.busy || remote.spaceTransition)
                    }
                    if let frame = depth.snapshot, let data = Data(base64Encoded: frame.preview_jpeg), let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 230)
                        Text(frame.source == "mock" ? "模拟相机 · 此窗口为左目预览" : "ZED · 此窗口为左目预览").font(.caption)
                    }
                    Button(remote.inSpace ? "退出立体视角" : "进入立体视角") {
                        remote.spaceTransition = true
                        Task {
                            defer { remote.spaceTransition = false }
                            if remote.inSpace { await dismissSpace(); remote.inSpace = false }
                            else {
                                switch await openSpace(id: "StereoCamera") {
                                case .opened:
                                    if remote.connected { remote.inSpace = true }
                                    else { await dismissSpace() }
                                case .userCancelled: break
                                case .error: remote.error = "无法进入沉浸空间"
                                @unknown default: break
                                }
                            }
                        }
                    }.disabled((!remote.inSpace && !video.connected) || remote.spaceTransition)
                    Text("屏幕固定在空间中。头部转动只用于云台跟随；首次位置约在前方 1.8 米。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("云台跟随") {
                    Text(control.status).foregroundStyle(.secondary)
                    Toggle("使用模拟头部角度", isOn: $control.simulatedHead).disabled(control.controlling)
                    if control.simulatedHead {
                        LabeledContent("水平角", value: String(format: "%.0f°", control.yaw))
                        Slider(value: $control.yaw, in: -70...70).accessibilityLabel("模拟头部水平角")
                        LabeledContent("俯仰角", value: String(format: "%.0f°", control.pitch))
                        Slider(value: $control.pitch, in: -35...35).accessibilityLabel("模拟头部俯仰角")
                    }
                    Button(control.controlling ? "停止跟随" : "以当前姿态开始跟随") {
                        if control.controlling { control.stop() } else { remote.startControl() }
                    }.disabled(!remote.connected || remote.capabilities?.head_control != true)
                    Text("只映射头部转动。重新开始可重置姿态基准；停止或失联时云台保持当前位置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = remote.error { Section("状态") { Text(error).foregroundStyle(.red) } }
                if let error = video.error { Section("视频状态") { Text(error).foregroundStyle(.red) } }
                if let error = control.error { Section("控制状态") { Text(error).foregroundStyle(.red) } }
                if let error = depth.error { Section("快照状态") { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("远程双目视角")
        }
    }
}
