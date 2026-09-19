import SwiftUI
import LiveKitWebRTC // 1. 确保导入 LiveKitWebRTC 框架
import AVFoundation

// MARK: - 视频渲染视图 (UIViewRepresentable)
// 这是 SwiftUI 与 UIKit 的桥梁，用于在 SwiftUI 视图中显示 WebRTC 的视频内容。
struct RTCVideoView: UIViewRepresentable {
    // 使用 LKRTCMTLVideoView 作为底层的视频渲染视图。
    // LKRTCMTLVideoView 是 LiveKitWebRTC 框架提供的基于 Metal 的高效渲染视图。
    typealias UIViewType = LKRTCMTLVideoView

    let videoTrack: LKRTCVideoTrack?
    @Binding var dimensions: CGSize?

    func makeUIView(context: Context) -> LKRTCMTLVideoView {
        let uiView = LKRTCMTLVideoView(frame: .zero)
        uiView.videoContentMode = .scaleAspectFill // 视频内容填充模式
        uiView.delegate = context.coordinator
        videoTrack?.add(uiView) // 将视频轨道附加到视图上进行渲染
        return uiView
    }

    func updateUIView(_ uiView: LKRTCMTLVideoView, context: Context) {
        // 当 track 变化时，更新渲染视图
        if let track = videoTrack, context.coordinator.track != track {
            context.coordinator.track?.remove(uiView)
            track.add(uiView)
            context.coordinator.track = track
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // Coordinator 用于处理来自 LKRTCMTLVideoViewDelegate 的回调
    class Coordinator: NSObject, LKRTCMTLVideoViewDelegate {
        private var parent: RTCVideoView
        var track: LKRTCVideoTrack?

        init(_ parent: RTCVideoView) {
            self.parent = parent
            self.track = parent.videoTrack
        }
        
        // 当视频帧的尺寸发生变化时调用
        func videoView(_ videoView: LKRTCMTLVideoView, didChangeVideoSize size: CGSize) {
            DispatchQueue.main.async {
                print("Video size changed to: \(size)")
                self.parent.dimensions = size
            }
        }
    }
}


// MARK: - WebRTC 客户端 (ObservableObject)
// 负责处理所有 WebRTC 连接、信令交互和媒体流。
class WebRTCClient: NSObject, ObservableObject, LKRTCPeerConnectionDelegate {

    // MARK: - Published Properties
    // 使用 @Published 属性包装器，当这些属性值改变时，SwiftUI 会自动更新相关的视图。
    @Published var leftVideoTrack: LKRTCVideoTrack?
    @Published var rightVideoTrack: LKRTCVideoTrack?
    @Published var connectionState: LKRTCIceConnectionState = .new
    @Published var leftVideoDimensions: CGSize?
    @Published var rightVideoDimensions: CGSize?

    // MARK: - Private Properties
    private var peerConnection: LKRTCPeerConnection?
    private let peerConnectionFactory: LKRTCPeerConnectionFactory
    
    // 请务必将此地址替换为你的信令服务器地址
    private let serverURL = URL(string: "http://YOUR_CAPTURE_SERVER_IP:8080/offer")!

    // MARK: - Initializer
    override init() {
        // 初始化 WebRTC 的编解码器工厂
        let encoderFactory = LKRTCDefaultVideoEncoderFactory()
        let decoderFactory = LKRTCDefaultVideoDecoderFactory()
        // 创建 PeerConnection 工厂，这是创建 PeerConnection 的入口点
        self.peerConnectionFactory = LKRTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }

    // MARK: - Connection Logic
    func connect() {
        guard peerConnection == nil else {
            print("Already connected.")
            return
        }

        // 1. 配置 PeerConnection
        let config = LKRTCConfiguration()
        // 通常在这里配置 STUN/TURN 服务器，但此示例为空
        config.iceServers = []
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        // 2. 创建 PeerConnection 实例
        guard let pc = self.peerConnectionFactory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            fatalError("Failed to create PeerConnection.")
        }
        self.peerConnection = pc

        // 3. 设置媒体流接收器 (Transceiver)
        // 我们期望接收两个只收不发的视频流
        pc.addTransceiver(of: .video, init: .init(direction: .recvOnly))
        pc.addTransceiver(of: .video, init: .init(direction: .recvOnly))

        // 4. 创建 Offer (SDP)
        pc.offer(for: .init(offerToReceiveVideo: true, offerToReceiveAudio: false)) { [weak self] offer, error in
            guard let self = self, let offer = offer else {
                if let error = error { print("Error creating offer: \(error)") }
                return
            }
            
            // 5. 设置本地描述 (Local Description)
            pc.setLocalDescription(offer) { [weak self] error in
                if let error = error {
                    print("Error setting local description: \(error)")
                    return
                }
                // 6. 发送 Offer 到信令服务器
                self?.sendOffer(offer)
            }
        }
    }

    // MARK: - Signaling
    private func sendOffer(_ offer: LKRTCSessionDescription) {
        print("Sending offer to server...")
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["sdp": offer.sdp, "type": "offer"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data else {
                if let error = error { print("Error sending offer: \(error)") }
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String]
                guard let sdp = json?["sdp"], json?["type"] == "answer" else {
                    print("Received invalid answer from server")
                    return
                }
                
                print("Received answer from server.")
                // 7. 收到 Answer 后，设置为远程描述 (Remote Description)
                let answer = LKRTCSessionDescription(type: .answer, sdp: sdp)
                self.peerConnection?.setRemoteDescription(answer) { error in
                    if let error = error {
                        print("Error setting remote description: \(error)")
                    } else {
                        print("Remote description set successfully.")
                    }
                }
            } catch {
                print("Error parsing server answer: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Disconnect Logic
    func disconnect() {
        guard let pc = peerConnection else { return }
        pc.close()
        self.peerConnection = nil
        self.leftVideoTrack = nil
        self.rightVideoTrack = nil
        self.connectionState = .closed
        print("Connection closed.")
    }

    // MARK: - LKRTCPeerConnectionDelegate
    // 当 ICE 连接状态发生变化时调用 (例如：正在连接、已连接、断开)
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange state: LKRTCIceConnectionState) {
        DispatchQueue.main.async {
            print("ICE connection state changed: \(state.description)")
            self.connectionState = state
        }
    }

    // 当新的媒体轨道 (Track) 到达时调用
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
        
        DispatchQueue.main.async {
            // 根据到达顺序分配给左右视频轨道
            if self.leftVideoTrack == nil {
                print("Received left video track.")
                self.leftVideoTrack = track
            } else if self.rightVideoTrack == nil {
                print("Received right video track.")
                self.rightVideoTrack = track
            }
        }
    }
    
    // --- 其他必须实现的代理方法 (即使为空) ---
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        // 这个旧的代理方法可以忽略
    }
    
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {}
}


// MARK: - 主视图 (ContentView)
struct ContentView: View {
    // 使用 @StateObject 来创建和管理 WebRTCClient 的生命周期
    @StateObject private var webRTCClient = WebRTCClient()

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            Text("WebRTC Stereo Stream")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding()

            // 视频显示区域
            HStack(spacing: 15) {
                VideoContainerView(
                    videoTrack: webRTCClient.leftVideoTrack,
                    dimensions: $webRTCClient.leftVideoDimensions,
                    label: "Left Eye"
                )
                VideoContainerView(
                    videoTrack: webRTCClient.rightVideoTrack,
                    dimensions: $webRTCClient.rightVideoDimensions,
                    label: "Right Eye"
                )
            }
            .padding(.horizontal)

            // 状态和控制面板
            VStack {
                // 连接状态
                Text("State: \(webRTCClient.connectionState.description)")
                    .font(.headline)
                    .padding(.top)
                
                // 控制按钮
                HStack(spacing: 20) {
                    Button("Connect") {
                        webRTCClient.connect()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    
                    Button("Disconnect") {
                        webRTCClient.disconnect()
                    }
                    .buttonStyle(PrimaryButtonStyle(backgroundColor: .red))
                }
                .padding(.vertical)
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(20)
            .padding()
        }
        .background(Color(.systemBackground))
        .edgesIgnoringSafeArea(.bottom)
        .onDisappear {
            // 当视图消失时，确保断开连接以释放资源
            webRTCClient.disconnect()
        }
    }
}

// MARK: - 辅助视图和样式

// 包含视频和标签的容器视图
struct VideoContainerView: View {
    let videoTrack: LKRTCVideoTrack?
    @Binding var dimensions: CGSize?
    let label: String
    
    var body: some View {
        VStack(spacing: 5) {
            RTCVideoView(videoTrack: videoTrack, dimensions: $dimensions)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .aspectRatio(dimensions ?? CGSize(width: 16, height: 9), contentMode: .fit)
                .shadow(radius: 5)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// 自定义按钮样式
struct PrimaryButtonStyle: ButtonStyle {
    var backgroundColor: Color = .blue
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .foregroundColor(.white)
            .font(.body.bold())
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut, value: configuration.isPressed)
    }
}


// MARK: - 扩展 (Extensions)
// 为 LKRTCIceConnectionState 添加一个可读的描述，方便在 UI 中显示。
extension LKRTCIceConnectionState {
    var description: String {
        switch self {
        case .new: return "New"
        case .checking: return "Checking"
        case .connected: return "Connected"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        case .closed: return "Closed"
        case .count: return "Count" // 通常不会用到
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - 预览 (Preview)
#Preview {
    ContentView()
}
