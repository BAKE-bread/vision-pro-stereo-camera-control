import AVFoundation
import Combine
import Foundation

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published var error: String?
    @Published private(set) var importing = false
    @Published private(set) var importProgress: ImportProgress?
    @Published var presenting = false
    @Published private(set) var playingID: UUID?
    let player = AVPlayer()
    private let store: MediaLibraryStore
    private var manifestReadable = true
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var playbackGeneration = UUID()
    private var importGeneration = UUID()
    private var wantsPlayback = false

    init(directory: URL? = nil) {
        store = MediaLibraryStore(directory: directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        do { items = try store.load() }
        catch {
            manifestReadable = false
            self.error = "无法读取播放列表，原文件已保留；修复前不会覆盖：\(error.localizedDescription)"
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.savePlaybackPosition() }
        }
    }

    deinit {
        observation?.invalidate()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func importVideos(_ urls: [URL]) async {
        guard !importing, manifestReadable, !urls.isEmpty else { return }
        importing = true; error = nil
        let attempt = UUID(); importGeneration = attempt
        defer { importing = false; importProgress = nil }
        for (index, url) in urls.enumerated() {
            importProgress = ImportProgress(title: url.lastPathComponent, fileIndex: index + 1, fileCount: urls.count)
            do {
                let directory = store.directory
                let report: @Sendable (Int64, Int64) -> Void = { [weak self] copied, total in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.importGeneration == attempt, self.importProgress?.fileIndex == index + 1 else { return }
                        self.importProgress?.copiedBytes = copied
                        self.importProgress?.totalBytes = total
                    }
                }
                let name = try await Task.detached(priority: .userInitiated) {
                    try MediaImporter.copy(url, to: directory, progress: report)
                }.value
                let item = LibraryItem(id: UUID(), title: url.deletingPathExtension().lastPathComponent, location: name, local: true)
                try commit(items + [item])
            } catch { self.error = "导入失败（\(url.lastPathComponent)）：\(error.localizedDescription)" }
        }
    }

    func addNetwork(_ text: String) {
        do {
            let url = try MediaLibraryStore.networkURL(text)
            if let existing = items.first(where: { !$0.local && $0.location == url.absoluteString }) {
                play(existing); return
            }
            let item = LibraryItem(id: UUID(), title: url.lastPathComponent.isEmpty ? (url.host ?? "网络视频") : url.lastPathComponent,
                                   location: url.absoluteString, local: false)
            try commit(items + [item])
            play(item)
        } catch { self.error = error.localizedDescription }
    }

    func play(_ item: LibraryItem, resume: Bool = true) {
        pause()
        do {
            let url = try store.url(for: item)
            let savedItem = items.first(where: { $0.id == item.id }) ?? item
            error = nil
            playbackGeneration = UUID()
            let attempt = playbackGeneration
            playingID = item.id
            observation?.invalidate()
            if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            let asset = AVPlayerItem(url: url)
            observation = asset.observe(\.status, options: [.new, .initial]) { [weak self] asset, _ in
                let status = asset.status
                let message = asset.error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, attempt == self.playbackGeneration else { return }
                    switch status {
                    case .failed:
                        self.error = message ?? "不支持的视频格式"
                        self.player.pause(); self.presenting = false
                    case .readyToPlay:
                        let duration = asset.duration.seconds
                        let position = resume ? (savedItem.resumeSeconds ?? 0) : 0
                        let start = position.isFinite && position > 0 && duration.isFinite && position < duration - 2 ? position : 0
                        if start > 0 {
                            self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { [weak self] finished in
                                Task { @MainActor in
                                    guard let self, finished, attempt == self.playbackGeneration, self.presenting, self.wantsPlayback else { return }
                                    self.player.play()
                                }
                            }
                        } else if self.presenting && self.wantsPlayback { self.player.play() }
                    default: break
                    }
                }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: asset, queue: .main) { [weak self] notice in
                let message = (notice.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放中断"
                Task { @MainActor in
                    guard let self, attempt == self.playbackGeneration else { return }
                    self.error = message; self.player.pause(); self.presenting = false
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: asset, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, attempt == self.playbackGeneration else { return }
                    self.savePlaybackPosition(completed: true)
                }
            }
            player.replaceCurrentItem(with: asset)
            wantsPlayback = true; presenting = true
        } catch { self.error = error.localizedDescription }
    }

    func pause() {
        wantsPlayback = false
        player.pause()
        savePlaybackPosition()
    }

    private func savePlaybackPosition(completed: Bool = false) {
        guard let id = playingID, let index = items.firstIndex(where: { $0.id == id }),
              let asset = player.currentItem, asset.status == .readyToPlay else { return }
        let time = player.currentTime().seconds, duration = asset.duration.seconds
        // Live streams without a finite timeline do not have a resume position.
        guard time.isFinite, duration.isFinite, duration > 0 else { return }
        var updated = items
        updated[index].resumeSeconds = completed || time >= duration - 2 ? 0 : max(0, time)
        updated[index].durationSeconds = duration
        do { try commit(updated) } catch { self.error = "保存播放进度失败：\(error.localizedDescription)" }
    }

    private func commit(_ updated: [LibraryItem]) throws {
        guard manifestReadable else { throw APIError(message: "播放列表损坏，已保留原文件；请先恢复 library.json") }
        try store.save(updated)
        items = updated
    }
}
