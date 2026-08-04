import XCTest
@testable import Litter

final class SavedAppsStoreTests: XCTestCase {
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SavedAppsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDir = url.path
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        super.tearDown()
    }

    func testPromoteWritesIndexAndHtmlToDisk() throws {
        let app = try savedAppPromote(
            directory: tempDir,
            title: "Fitness Tracker",
            widgetHtml: "<div id='x'>Hi</div>",
            width: 360,
            height: 640,
            originThreadId: "origin-123"
        )

        let fm = FileManager.default
        let indexPath = (tempDir as NSString).appendingPathComponent("saved_apps.json")
        XCTAssertTrue(fm.fileExists(atPath: indexPath), "saved_apps.json should exist")

        let htmlPath = (tempDir as NSString).appendingPathComponent("html/\(app.id).html")
        XCTAssertTrue(fm.fileExists(atPath: htmlPath), "per-app html file should exist")

        let snapshot = savedAppsList(directory: tempDir)
        XCTAssertEqual(snapshot.apps.count, 1)
        XCTAssertEqual(snapshot.apps.first?.title, "Fitness Tracker")
        XCTAssertEqual(snapshot.apps.first?.originThreadId, "origin-123")
    }

    func testSaveStateRoundTrips() throws {
        let app = try savedAppPromote(
            directory: tempDir,
            title: "Counter",
            widgetHtml: "<p>x</p>",
            width: 320,
            height: 480,
            originThreadId: nil
        )

        _ = try savedAppSaveState(
            directory: tempDir,
            appId: app.id,
            stateJson: "{\"count\":3}",
            schemaVersion: 2
        )

        let loaded = savedAppLoadState(directory: tempDir, appId: app.id)
        XCTAssertEqual(loaded?.stateJson, "{\"count\":3}")
        XCTAssertEqual(loaded?.schemaVersion, 2)
    }

    func testDeleteRemovesIndexEntryAndHtmlFile() throws {
        let app = try savedAppPromote(
            directory: tempDir,
            title: "X",
            widgetHtml: "<p/>",
            width: 320,
            height: 240,
            originThreadId: nil
        )

        try savedAppDelete(directory: tempDir, appId: app.id)

        let snapshot = savedAppsList(directory: tempDir)
        XCTAssertTrue(snapshot.apps.isEmpty)

        let htmlPath = (tempDir as NSString).appendingPathComponent("html/\(app.id).html")
        XCTAssertFalse(FileManager.default.fileExists(atPath: htmlPath))
    }
}
