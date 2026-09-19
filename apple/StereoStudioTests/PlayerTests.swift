import XCTest
@testable import StereoStudio

@MainActor
final class PlayerTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StereoStudioTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLegacyLibraryAndResumePersistence() throws {
        let store = MediaLibraryStore(directory: try directory())
        let old = """
            [{"id":"00000000-0000-0000-0000-000000000001","title":"Original","location":"movie.mp4","local":true}]
            """
        try Data(old.utf8).write(to: store.manifest)
        var items = try store.load()
        XCTAssertNil(items[0].resumeSeconds)
        items[0].resumeSeconds = 42
        items[0].durationSeconds = 90
        try store.save(items)
        XCTAssertEqual(try store.load()[0].resumeSeconds, 42)
        XCTAssertEqual(try store.load()[0].durationSeconds, 90)
    }

    func testImportCopiesOriginalAndPersistsOnlyCompletedFiles() async throws {
        let sourceDirectory = try directory(), destination = try directory()
        let source = sourceDirectory.appendingPathComponent("sample.mov")
        let original = Data(repeating: 0x42, count: 2_200_000)
        try original.write(to: source)
        let library = LibraryModel(directory: destination)
        await library.importVideos([source])
        XCTAssertNil(library.error)
        XCTAssertFalse(library.importing)
        XCTAssertNil(library.importProgress)
        let item = try XCTUnwrap(library.items.first)
        XCTAssertNotEqual(item.location, "sample.mov")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(item.location)), original)
        XCTAssertEqual(try MediaLibraryStore(directory: destination).load().count, 1)
    }

    func testFailedImportDoesNotCreatePlaylistEntry() async throws {
        let destination = try directory()
        let library = LibraryModel(directory: destination)
        await library.importVideos([destination.appendingPathComponent("missing.mov")])
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertNotNil(library.error)
    }

    func testCorruptedManifestIsNotOverwritten() throws {
        let directory = try directory()
        let manifest = directory.appendingPathComponent("library.json")
        let damaged = Data("not valid json".utf8)
        try damaged.write(to: manifest)
        let library = LibraryModel(directory: directory)
        library.addNetwork("https://example.com/video.mp4")
        XCTAssertEqual(try Data(contentsOf: manifest), damaged)
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertNotNil(library.error)
    }

    func testLibraryRejectsPathTraversalAndEmbeddedCredentials() throws {
        let store = MediaLibraryStore(directory: try directory())
        let item = LibraryItem(id: UUID(), title: "Invalid", location: "../outside.mp4", local: true)
        XCTAssertThrowsError(try store.url(for: item))
        XCTAssertThrowsError(try MediaLibraryStore.networkURL("https://user:password@example.com/video.mp4"))
        XCTAssertThrowsError(try MediaLibraryStore.networkURL("rtsp://camera/live"))
    }
}
