import Foundation

struct Capabilities: Decodable {
    let `protocol`: Int
    let source: String
    let stereo_layout: String
    let eye_width: Int
    let eye_height: Int
    let head_control: Bool
    let livekit: Bool
    let video_status: String
}
struct StreamSession: Decodable {
    let url: String
    let token: String
    let track_name: String
    let layout: String
    let publisher_identity: String?

    func accepts(publisher: String?, trackName: String) -> Bool {
        layout == "top-bottom" && trackName == track_name && publisher == (publisher_identity ?? "stereo-camera")
    }
}
struct DepthSnapshot: Decodable {
    let `protocol`: Int
    let unit: String
    let alignment: String
    let frame_id: Int
    let source: String
    let captured_at_ms: Int64
    let age_ms: Int
    let width: Int
    let height: Int
    let preview_jpeg: String
    let depth_width: Int
    let depth_height: Int
    let depth_m: [Double?]
    let near_m: Double?
    let near_warning: Bool
    let valid_fraction: Double

    func validate() throws {
        guard self.protocol == 1, unit == "m", alignment == "left", frame_id > 0,
              width > 0, height > 0, depth_width > 0, depth_height > 0,
              depth_width <= 4096, depth_height <= 4096,
              depth_m.count == depth_width * depth_height,
              age_ms >= 0, age_ms < 750, (0...1).contains(valid_fraction),
              depth_m.allSatisfy({ $0 == nil || ($0!.isFinite && $0! > 0) }) else {
            throw APIError(message: "深度帧无效或已过期")
        }
    }
}
struct Measurement: Decodable {
    let frame_id: Int
    let valid: Bool
    let axial_m: Double?
    let range_m: Double?
}
struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct APIClient {
    let base: URL
    let token: String
    let session: URLSession

    init(address: String, token: String, session: URLSession = .shared) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw APIError(message: "请输入服务器 HTTP/HTTPS 地址（不含查询参数或片段）") }
        self.base = url; self.token = token; self.session = session
    }
    func request<T: Decodable>(_ path: String, body: Data? = nil) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent("api/" + path))
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw APIError(message: detail.map { String(describing: $0) } ?? "服务器响应异常")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func controlURL() throws -> URL {
        guard var parts = URLComponents(url: base.appendingPathComponent("api/control"), resolvingAgainstBaseURL: false) else { throw APIError(message: "控制地址无效") }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        guard let url = parts.url else { throw APIError(message: "控制地址无效") }
        return url
    }
}
