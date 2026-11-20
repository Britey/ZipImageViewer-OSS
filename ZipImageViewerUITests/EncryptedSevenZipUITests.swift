import XCTest

final class EncryptedSevenZipUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ fixture: String) throws -> XCUIApplication {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Fixture injection is available only in simulator Debug builds.")
        #else
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture,
                                                        withExtension: "7z", subdirectory: "SevenZip"))
        let app = XCUIApplication()
        app.launchEnvironment["ZIPIMAGEVIEWER_TEST_ARCHIVE"] = try Data(contentsOf: url).base64EncodedString()
        app.launchEnvironment["ZIPIMAGEVIEWER_LEGACY_UI_TESTS"] = "1"
        app.launch()
        return app
        #endif
    }

    @MainActor
    private func enterPassword(_ password: String, in app: XCUIApplication, action: String) {
        let field = app.secureTextFields["sevenZipPassword"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(password)
        app.alerts.buttons[action].tap()
    }

    @MainActor
    func testEncryptedContentsOpenInViewer() throws {
        let app = try launch("content-lzma2-solid")
        enterPassword("test-password", in: app, action: "Open")
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 10))
        app.buttons["readerClose"].tap()
        XCTAssertTrue(app.buttons["openArchive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openArchive"].isEnabled)
    }

    @MainActor
    func testEncryptedHeadersRetryWrongPasswordThenOpen() throws {
        let app = try launch("headers-lzma-solid")
        enterPassword("wrong", in: app, action: "Try Password")
        // A new alert must survive the previous alert's dismissal animation.
        enterPassword("test-password", in: app, action: "Try Password")
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testWrongContentPasswordRetryThenOpen() throws {
        let app = try launch("content-lzma2-solid")
        enterPassword("wrong", in: app, action: "Open")
        enterPassword("test-password", in: app, action: "Try Again")
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testCancelPasswordRestoresOpenButton() throws {
        let app = try launch("headers-lzma-solid")
        XCTAssertTrue(app.secureTextFields["sevenZipPassword"].waitForExistence(timeout: 10))
        app.alerts.buttons["Cancel"].tap()
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: app.buttons["openArchive"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["archiveImportStage"].exists)
        XCTAssertFalse(app.buttons["readerClose"].exists)
    }

    @MainActor
    func testOrdinaryArchiveDoesNotAskForPassword() throws {
        let app = try launch("plain-lzma-solid")
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.secureTextFields["sevenZipPassword"].exists)
    }

    @MainActor
    func testPasswordWhitespaceSurvivesTheDialog() throws {
        let app = try launch("whitespace-password")
        enterPassword("  padded password  ", in: app, action: "Try Password")
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testBackgroundingCancelsPendingPassword() throws {
        let app = try launch("headers-lzma-solid")
        XCTAssertTrue(app.secureTextFields["sevenZipPassword"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        // Home can return while SpringBoard is still animating. Observe the
        // background transition before requesting foreground activation.
        expectation(for: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: app.buttons["openArchive"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.secureTextFields["sevenZipPassword"].exists)
        XCTAssertFalse(app.staticTexts["archiveImportStage"].exists)
    }
}
