import Foundation

struct LibraryItem: Identifiable, Codable {
    var id: UUID
    var title: String
    var location: String
    var local: Bool
    var resumeSeconds: Double?
    var durationSeconds: Double?
}

struct MediaLibraryStore {
    let directory: URL
    var manifest: URL { directory.appendingPathComponent("library.json") }

    func load() throws -> [LibraryItem] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let items = try JSONDecoder().decode([LibraryItem].self, from: Data(contentsOf: manifest))
        guard Set(items.map(\.id)).count == items.count else { throw APIError(message: "播放列表含重复条目编号") }
        for item in items {
            _ = try url(for: item)
            for seconds in [item.resumeSeconds, item.durationSeconds].compactMap({ $0 }) {
                guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { throw APIError(message: "播放进度数据无效") }
            }
        }
        return items
    }

    func save(_ items: [LibraryItem]) throws {
        try JSONEncoder().encode(items).write(to: manifest, options: .atomic)
    }

    func url(for item: LibraryItem) throws -> URL {
        if item.local {
            let url = directory.appendingPathComponent(item.location).standardizedFileURL
            guard !item.location.isEmpty, url.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
                throw APIError(message: "播放列表中的本地路径无效")
            }
            return url
        }
        return try Self.networkURL(item.location)
    }

    static func networkURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else {
            throw APIError(message: "请输入不含用户名和密码的 HTTP/HTTPS 视频或 HLS 地址。RTSP/RTMP 请在服务器转换。")
        }
        return url
    }
}

struct ImportProgress {
    let title: String
    let fileIndex: Int
    let fileCount: Int
    var copiedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var fraction: Double { totalBytes > 0 ? min(1, Double(copiedBytes) / Double(totalBytes)) : 0 }
}

enum MediaImporter {
    /// Coordinates cloud-backed files and keeps the original file untouched.
    static func copy(_ source: URL, to directory: URL,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result {
                let id = UUID().uuidString
                let name = id + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                let staging = directory.appendingPathComponent(id + ".importing")
                let destination = directory.appendingPathComponent(name)
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
                    throw APIError(message: "无法创建导入文件，请检查可用存储空间")
                }
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: staging)
                defer { try? output.close() }
                var copied: Int64 = 0
                var lastReport = ProcessInfo.processInfo.systemUptime
                progress(0, size)
                while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    copied += Int64(chunk.count)
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastReport >= 0.1 { progress(copied, size); lastReport = now }
                }
                try output.synchronize()
                guard copied > 0, size == 0 || copied == size else { throw APIError(message: "视频文件为空或未能完整读取") }
                try FileManager.default.moveItem(at: staging, to: destination)
                progress(copied, copied)
                return name
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw APIError(message: "文件协调器未能读取视频") }
        // Failed partial copies remain outside the playlist for recovery; no source deletion.
        return try result.get()
    }
}
