// 最简单的版本，使用WebKit

import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    // 将 YOUR_SERVER_IP 替换为您的采集服务器的IP地址
    let url = URL(string: "http://192.168.5.17:8080")!

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        uiView.load(request)
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black
            WebView()
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}


/*
// 稍复杂的版本

import SwiftUI
import WebKit // 1. 导入WebKit框架

// 2. 创建一个包装WKWebView的SwiftUI视图
struct WebView: UIViewRepresentable {
    
    // 将 YOUR_SERVER_IP 替换为您的采集服务器的IP地址
    let url = URL(string: "http://YOUR_SERVER_IP:8080")!

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        
        // --- 让网页看起来更像原生App的关键配置 ---
        
        // a. 设置背景透明，使其与SwiftUI的背景融为一体
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear
        
        // b. 禁用各种滚动和缩放手势，让它像一个静态视图
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        uiView.load(request)
    }
}

// 3. 主视图，现在嵌入了WebView
struct ContentView: View {
    var body: some View {
        // 使用ZStack将WebView放在最底层
        ZStack {
            // 设置一个深色的背景，与您的网页风格匹配
            Color.black.edgesIgnoringSafeArea(.all)
            
            // 调用创建的WebView
            WebView()
                // 应用一个遮罩，确保视频内容被限制在视觉安全的圆角矩形内
                .clipShape(RoundedRectangle(cornerRadius: 30))
                .padding(20) // 在窗口边缘留出一些空间
        }
    }
}

#Preview {
    ContentView()
}*/


/*
// 只能在Apple Vision Designed for iPad运行的版本

import SwiftUI
import WebRTC // https://github.com/stasel/WebRTC需要导入相关包
import RealityKit

// 1. WebRTC视频渲染视图
struct RTCVideoView: UIViewRepresentable {
    @ObservedObject var webRTCClient: WebRTCClient
    var isLeft: Bool

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        let track = isLeft ? webRTCClient.leftVideoTrack : webRTCClient.rightVideoTrack
        if let track = track {
            track.add(uiView)
        }
    }
}

// 2. WebRTC客户端 (完整定义)
// The full class definition is now included to resolve compiler errors.
class WebRTCClient: NSObject, ObservableObject, RTCPeerConnectionDelegate {
    @Published var leftVideoTrack: RTCVideoTrack?
    @Published var rightVideoTrack: RTCVideoTrack?
    @Published var connectionState: RTCIceConnectionState = .new

    // IMPORTANT: Replace "YOUR_CAPTURE_SERVER_IP" with the actual IP address of your Python server.
    private let serverURL = URL(string: ç)!
    private var peerConnection: RTCPeerConnection?
    private let peerConnectionFactory: RTCPeerConnectionFactory

    override init() {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.peerConnectionFactory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }

    func connect() {
        let config = RTCConfiguration()
        config.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        self.peerConnection = self.peerConnectionFactory.peerConnection(with: config, constraints: constraints, delegate: self)

        guard let pc = self.peerConnection else { return }

        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: transceiverInit)
        pc.addTransceiver(of: .video, init: transceiverInit)

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "false"],
            optionalConstraints: nil
        )
        
        pc.offer(for: offerConstraints) { [weak self] offer, error in
            guard let self = self, let offer = offer, error == nil else {
                print("Error creating offer: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            pc.setLocalDescription(offer) { [weak self] error in
                guard let self = self, error == nil else {
                    print("Error setting local description: \(error?.localizedDescription ?? "Unknown error")")
                    return
                }
                self.sendOffer(offer)
            }
        }
    }

    private func sendOffer(_ offer: RTCSessionDescription) {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = ["sdp": offer.sdp, "type": "offer"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: String],
                  let sdp = json["sdp"], let typeString = json["type"], typeString == "answer"
            else {
                print("Failed to receive a valid answer from server. Error: \(String(describing: error))")
                return
            }

            let answer = RTCSessionDescription(type: .answer, sdp: sdp)
            self.peerConnection?.setRemoteDescription(answer) { error in
                if let error = error {
                    print("Error setting remote description: \(error)")
                }
            }
        }.resume()
    }

    // MARK: - RTCPeerConnectionDelegate Conformance
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = state
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async {
            if self.leftVideoTrack == nil {
                self.leftVideoTrack = track
            } else if self.rightVideoTrack == nil {
                self.rightVideoTrack = track
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate iceCandidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}


// 3. 主视图，并排(Side-by-Side)布局以在Vision Pro上触发3D模式
struct ContentView: View {
    @StateObject private var webRTCClient = WebRTCClient()
    @State private var showConnectionState = true

    var body: some View {
        ZStack {
            // 添加黑色背景以填充屏幕的任何未使用区域
            Color.black.ignoresSafeArea()

            ZStack(alignment: .bottom) {
                // 使用HStack将左右视频流并排显示，无任何间距
                HStack(spacing: 0) {
                    // 左眼视频流
                    RTCVideoView(webRTCClient: webRTCClient, isLeft: true)
                    
                    // 右眼视频流
                    RTCVideoView(webRTCClient: webRTCClient, isLeft: false)
                }
                // 强制HStack保持正确的宽高比 (2 * 1280 x 720 = 32:9)
                // 并使其适应窗口大小，这可以防止视频失真。
                .aspectRatio(CGSize(width: 2560, height: 720), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)


                // 连接状态指示器，连接成功后会自动淡出
                if showConnectionState {
                    Text("Connection State: \(webRTCClient.connectionState.description)")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.bottom, 20)
                        // 使用动画让状态指示器平滑消失
                        .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                }
            }
        }
        .onAppear {
            // 当视图出现时，开始连接
            webRTCClient.connect()
        }
        // 监听连接状态的变化
        .onChange(of: webRTCClient.connectionState) { oldState, newState in
            // 当连接状态变为 'completed' 或 'connected' 时，
            // 延迟3秒后隐藏状态指示器
            if newState == .completed || newState == .connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.showConnectionState = false
                }
            } else {
                // 如果断开连接，则重新显示状态
                self.showConnectionState = true
            }
        }
    }
}

// 扩展以获取连接状态的字符串描述
extension RTCIceConnectionState {
    var description: String {
        switch self {
        case .new: return "New"
        case .checking: return "Checking..."
        case .connected: return "Connected"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        case .closed: return "Closed"
        case .count: return "Count"
        @unknown default: return "Unknown"
        }
    }
}

#Preview {
    ContentView()
}
*/