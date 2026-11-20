import XCTest

final class RecentArchivesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func seededApp() throws -> XCUIApplication {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Fixture injection is available only in simulator Debug builds.")
        #else
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "plain",
                                                              withExtension: "cbz", subdirectory: "SevenZip"))
        let encoded = try Data(contentsOf: fixture).base64EncodedString()
        let fixtures = [["name": "First book.cbz", "base64": encoded],
                        ["name": "Second book.zip", "base64": encoded]]
        let app = XCUIApplication()
        app.launchEnvironment["ZIPIMAGEVIEWER_TEST_CACHE_ID"] = UUID().uuidString
        app.launchEnvironment["ZIPIMAGEVIEWER_TEST_RECENT_FIXTURES"] = String(
            data: try JSONSerialization.data(withJSONObject: fixtures), encoding: .utf8)
        app.launchEnvironment["ZIPIMAGEVIEWER_LEGACY_UI_TESTS"] = "1"
        app.launch()
        return app
        #endif
    }

    @MainActor
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    @MainActor
    func testCompressionSettingDefaultsOffAndPersistsWithoutRemovingExistingCaches() throws {
        let app = try seededApp()
        XCTAssertTrue(row("First book.cbz", in: app).waitForExistence(timeout: 15))
        func openCompressionSetting() -> XCUIElement {
            app.buttons["openSettings"].tap()
            let toggle = app.switches["compressExtractedImages"]
            for _ in 0..<5 {
                if toggle.exists && toggle.isHittable { break }
                app.tables["readerSettings"].swipeUp()
            }
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            return toggle
        }
        let toggle = openCompressionSetting()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        expectation(for: NSPredicate(format: "value == '1' AND enabled == true"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ZIPIMAGEVIEWER_TEST_RECENT_FIXTURES")
        app.launchEnvironment["ZIPIMAGEVIEWER_LEGACY_UI_TESTS"] = "1"
        app.launch()
        XCTAssertTrue(row("First book.cbz", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(row("Second book.zip", in: app).exists)
        XCTAssertEqual(openCompressionSetting().value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Optional cache compression setting"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testRecentArchiveResumesAfterRelaunchWithoutReselectingSource() throws {
        let app = try seededApp()
        let first = row("First book.cbz", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(row("Second book.zip", in: app).exists)
        let homeScreenshot = XCTAttachment(screenshot: app.screenshot())
        homeScreenshot.name = "Home before opening archive"
        homeScreenshot.lifetime = .keepAlways
        add(homeScreenshot)
        first.tap()
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 10))
        let readerScreenshot = XCTAttachment(screenshot: app.screenshot())
        readerScreenshot.name = "Reader status bar hidden"
        readerScreenshot.lifetime = .keepAlways
        add(readerScreenshot)
        // The tappable page-number label is exposed as an accessibility button.
        XCTAssertEqual(app.buttons["readerPageButton"].value as? String, "Current page 1 of 3")
        app.swipeLeft()
        expectation(for: NSPredicate(format: "value == %@", "Current page 2 of 3"), evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 5)
        app.buttons["readerClose"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let restoredScreenshot = XCTAttachment(screenshot: app.screenshot())
        restoredScreenshot.name = "Home status bar restored"
        restoredScreenshot.lifetime = .keepAlways
        add(restoredScreenshot)
        let saved = NSPredicate(format: "label CONTAINS %@", "Page 2 of 3")
        expectation(for: saved, evaluatedWith: first)
        waitForExpectations(timeout: 5)

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ZIPIMAGEVIEWER_TEST_RECENT_FIXTURES")
        app.launchEnvironment["ZIPIMAGEVIEWER_LEGACY_UI_TESTS"] = "1"
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(row("Second book.zip", in: app).exists)
        first.tap()
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["readerPageButton"].value as? String, "Current page 2 of 3")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
    }

    @MainActor
    func testRemovingOneRecentArchivePreservesTheOtherAfterRelaunch() throws {
        let app = try seededApp()
        let first = row("First book.cbz", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.press(forDuration: 1)
        let remove = app.buttons["Remove Cached Archive…"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(app.alerts.buttons["Remove"].waitForExistence(timeout: 5))
        app.alerts.buttons["Remove"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: first)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(row("Second book.zip", in: app).exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ZIPIMAGEVIEWER_TEST_RECENT_FIXTURES")
        app.launchEnvironment["ZIPIMAGEVIEWER_LEGACY_UI_TESTS"] = "1"
        app.launch()
        XCTAssertTrue(row("Second book.zip", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(first.exists)
    }
}
