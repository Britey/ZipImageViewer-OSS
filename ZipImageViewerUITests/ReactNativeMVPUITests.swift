import XCTest

/// Executes the production RN root with bundled JS. Native-only suites explicitly
/// retain their legacy harness and are not counted as shared-screen coverage.
final class ReactNativeMVPUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func confirmPageJump(in app: XCUIApplication) {
        let popover = app.otherElements["PopoverDismissRegion"].firstMatch
        if popover.waitForExistence(timeout: 1) { popover.tap() }
        let confirm = app.buttons["confirmPageJump"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        confirm.tap()
    }

    @MainActor
    private func launch(fixture: String? = nil, id: String = UUID().uuidString) throws -> XCUIApplication {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Disposable fixture injection requires Debug simulator.")
        #else
        let app = XCUIApplication()
        app.launchEnvironment["ZIPIMAGEVIEWER_TEST_CACHE_ID"] = id
        app.launchEnvironment["ZIPIMAGEVIEWER_USE_BUNDLED_JS"] = "1"
        if let fixture {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "7z", subdirectory: "SevenZip"))
            app.launchEnvironment["ZIPIMAGEVIEWER_RN_TEST_ARCHIVE"] = try Data(contentsOf: url).base64EncodedString()
        }
        app.launch()
        return app
        #endif
    }

    @MainActor
    func testImageRotationButtonsGesturesPagesAndPersistence() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let id = UUID().uuidString
        let app = try launch(fixture: "headers-lzma-solid", id: id)
        let password = app.secureTextFields["passwordInput"]
        XCTAssertTrue(password.waitForExistence(timeout: 30))
        password.tap(); password.typeText("test-password"); app.buttons["submitPassword"].tap()
        XCTAssertTrue(app.buttons["readerSettings"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["readerRotateClockwise"].exists)
        app.buttons["readerSettings"].tap()
        let toggle = app.switches["Show image rotation buttons"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap(); app.buttons["readerSettingsDone"].tap()
        let clockwise = app.buttons["readerRotateClockwise"]
        let counter = app.buttons["readerRotateCounterclockwise"]
        XCTAssertTrue(clockwise.waitForExistence(timeout: 10))
        XCTAssertLessThan(counter.frame.midX, clockwise.frame.midX)
        XCTAssertLessThan(clockwise.frame.midX, app.buttons["readerSettings"].frame.midX)
        let canvas = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Reading canvas,")).firstMatch
        func rotation(_ degrees: Int) {
            let predicate = degrees == 0 ? NSPredicate(format: "NOT (value CONTAINS %@)", "image rotated")
                : NSPredicate(format: "value CONTAINS %@", "image rotated \(degrees) degrees clockwise")
            expectation(for: predicate, evaluatedWith: canvas); waitForExpectations(timeout: 10)
        }
        counter.tap(); rotation(270)
        clockwise.tap(); rotation(0)
        for degrees in [90, 180, 270, 0] { clockwise.tap(); rotation(degrees) }
        clockwise.tap(); rotation(90)
        let portrait = XCTAttachment(screenshot: app.screenshot()); portrait.name = "Rotation toolbar portrait"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["readerHide"].tap()
        canvas.pinch(withScale: 3, velocity: 1)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)))
        rotation(90)
        expectation(for: NSPredicate(format: "value CONTAINS %@ AND NOT (value CONTAINS %@)", "zoom ", "zoom 100 percent"), evaluatedWith: canvas)
        waitForExpectations(timeout: 10)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["readerPageButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["readerPageButton"].value as? String, "Current page 1 of 3")
        // A turn refits and returns to page-turn gestures, independent of orientation.
        counter.tap(); rotation(0)
        canvas.swipeLeft()
        expectation(for: NSPredicate(format: "value == %@", "Current page 2 of 3"), evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 10); rotation(0)
        clockwise.tap(); rotation(90)
        XCUIDevice.shared.orientation = .landscapeLeft
        var previousFrames: [CGRect] = []
        var stableSince = Date()
        expectation(for: NSPredicate { _, _ in
            let frames = [counter.frame, clockwise.frame, app.buttons["readerPages"].frame]
            guard app.frame.width > app.frame.height, frames.allSatisfy({ !$0.isEmpty && app.frame.contains($0) }),
                  counter.isHittable, clockwise.isHittable else { stableSince = Date(); return false }
            if frames != previousFrames { previousFrames = frames; stableSince = Date() }
            return Date().timeIntervalSince(stableSince) >= 1
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 10); rotation(90)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Rotation toolbar landscape"; landscape.lifetime = .keepAlways; add(landscape)
        counter.tap(); rotation(0)
        app.buttons["readerPages"].tap()
        XCTAssertTrue(app.buttons["thumbnail_0"].waitForExistence(timeout: 10)); app.buttons["thumbnail_0"].tap()
        rotation(0)
        app.buttons["readerSettings"].tap(); XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap(); app.buttons["readerSettingsDone"].tap()
        XCTAssertFalse(clockwise.exists)
        app.buttons["readerSettings"].tap(); toggle.tap(); app.buttons["readerSettingsDone"].tap()
        app.terminate()
        let relaunched = try launch(id: id)
        XCTAssertTrue(relaunched.buttons["openSettings"].waitForExistence(timeout: 30)); relaunched.buttons["openSettings"].tap()
        XCTAssertTrue(relaunched.switches["Show image rotation buttons"].waitForExistence(timeout: 10))
        XCTAssertEqual(relaunched.switches["Show image rotation buttons"].value as? String, "1")
    }

    @MainActor
    func testEmptyLibraryOpensRealPickerAndCanCancelRepeatedly() throws {
        let app = try launch()
        let open = app.buttons["openEmptyArchive"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        XCTAssertEqual(open.label, "Open archive")
        XCTAssertFalse(app.buttons["openSample"].exists)
        for _ in 0..<2 {
            open.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The native document picker must open")
            cancel.tap()
            expectation(for: NSPredicate(format: "hittable == true AND enabled == true"), evaluatedWith: open)
            waitForExpectations(timeout: 10)
            XCTAssertTrue(app.staticTexts["No archives yet"].exists)
            XCTAssertFalse(app.buttons["readerClose"].exists)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Empty library after repeated picker cancellation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSharedLibraryAndPersistedPreferences() throws {
        let id = UUID().uuidString
        let app = try launch(id: id)
        XCTAssertTrue(app.buttons["openArchive"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["redbox-error"].exists, "React Native must not mount an error overlay")
        app.buttons["openSettings"].tap()
        let toggle = app.switches["Show page slider"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.terminate()
        let relaunched = try launch(id: id)
        XCTAssertTrue(relaunched.buttons["openSettings"].waitForExistence(timeout: 30))
        relaunched.buttons["openSettings"].tap()
        XCTAssertTrue(relaunched.switches["Show page slider"].waitForExistence(timeout: 10))
        XCTAssertEqual(relaunched.switches["Show page slider"].value as? String, "0")
    }

    @MainActor
    func testDoubleTapSettingPreservesRapidPageTapsPinchAndPersistence() throws {
        let id = UUID().uuidString
        let app = try launch(fixture: "headers-lzma-solid", id: id)
        let password = app.secureTextFields["passwordInput"]
        XCTAssertTrue(password.waitForExistence(timeout: 30))
        password.tap(); password.typeText("test-password")
        app.buttons["submitPassword"].tap()
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 30))
        app.buttons["readerSettings"].tap()
        let toggle = app.switches["Double-tap to zoom"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        app.buttons["readerSettingsDone"].tap()
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.35))
        right.doubleTap()
        expectation(for: NSPredicate(format: "value == %@", "Current page 3 of 3"), evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 5)
        app.buttons["readerPageButton"].tap()
        let jump = app.textFields["pageNumberInput"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        XCTAssertTrue(app.frame.contains(jump.frame))
        jump.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        confirmPageJump(in: app)
        expectation(for: NSPredicate(format: "value == %@", "Current page 2 of 3"), evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 5)
        let canvas = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Reading canvas,")).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", "Page 2 of 3"), evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        // Send both fingers to the native canvas rather than the app-wide frame,
        // whose iPad bounds also include the shared toolbar and page slider.
        app.buttons["readerHide"].tap()
        // A full pinch keeps synthesized finger motion above UIKit's movement
        // threshold on large iPad displays; the native reader caps zoom at 3x.
        canvas.pinch(withScale: 3, velocity: 1)
        let zoomScreenshot = XCTAttachment(screenshot: app.screenshot())
        zoomScreenshot.name = "Native canvas pinch with double-tap zoom disabled"
        zoomScreenshot.lifetime = .keepAlways
        add(zoomScreenshot)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["readerPageButton"].waitForExistence(timeout: 10))
        right.doubleTap()
        XCTAssertEqual(app.buttons["readerPageButton"].value as? String, "Current page 2 of 3",
                       "Pinch zoom must survive disabled double taps and protect the page")
        app.buttons["readerSettings"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        app.buttons["readerSettingsDone"].tap()
        right.doubleTap() // Enabled: zoom out without turning a page.
        right.tap()
        expectation(for: NSPredicate(format: "value == %@", "Current page 3 of 3"), evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 5)
        app.buttons["readerSettings"].tap()
        toggle.tap()
        app.buttons["readerSettingsDone"].tap()
        app.terminate()
        let relaunched = try launch(id: id)
        XCTAssertTrue(relaunched.buttons["openSettings"].waitForExistence(timeout: 30))
        relaunched.buttons["openSettings"].tap()
        XCTAssertTrue(relaunched.switches["Double-tap to zoom"].waitForExistence(timeout: 10))
        XCTAssertEqual(relaunched.switches["Double-tap to zoom"].value as? String, "0")
    }

    @MainActor
    func testLibraryPasswordDialogSupportsLandscape() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = try launch(fixture: "headers-lzma-solid")
        XCTAssertTrue(app.secureTextFields["passwordInput"].waitForExistence(timeout: 30))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        wait(for: [landscape], timeout: 10)
        XCTAssertTrue(app.buttons["submitPassword"].isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Library password landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor
    func testSharedReaderRotationAndOverviewLayout() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = try launch(fixture: "headers-lzma-solid")
        let password = app.secureTextFields["passwordInput"]
        XCTAssertTrue(password.waitForExistence(timeout: 30))
        password.tap(); password.typeText("test-password")
        app.buttons["submitPassword"].tap()
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 30))
        XCUIDevice.shared.orientation = .landscapeLeft
        // Rotation reports its orientation before React's touch surfaces settle.
        // Wait for the actual landscape layout and a stable Pages button frame.
        var previousFrame = CGRect.null
        var stableSince = Date()
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.buttons["readerPages"].frame
            guard app.frame.width > app.frame.height, app.frame.contains(frame),
                  !frame.isEmpty else { stableSince = Date(); return false }
            if frame != previousFrame { previousFrame = frame; stableSince = Date() }
            return Date().timeIntervalSince(stableSince) >= 1
        }, object: nil)
        wait(for: [rotated], timeout: 10)
        XCTAssertTrue(app.buttons["readerClose"].isHittable)
        XCTAssertTrue(app.buttons["readerPageButton"].isHittable)
        app.buttons["readerPages"].tap()
        let thumbnailAppeared = app.buttons["thumbnail_2"].waitForExistence(timeout: 10)
        if !thumbnailAppeared {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Missing overview after rotation"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(thumbnailAppeared)
        XCTAssertTrue(app.buttons["thumbnail_2"].isHittable)
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The shared overview must retain landscape orientation")
        let overview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overview.name = "Shared overview landscape layout"
        overview.lifetime = .keepAlways
        add(overview)
        app.buttons["readerPagesDone"].tap()
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 5)
        app.buttons["readerClose"].tap()
        XCTAssertTrue(app.buttons["openArchive"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSharedPasswordOpensNativeReaderAndReturnsToSharedLibrary() throws {
        let id = UUID().uuidString
        let app = try launch(fixture: "headers-lzma-solid", id: id)
        let field = app.secureTextFields["passwordInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap(); field.typeText("test-password")
        app.buttons["submitPassword"].tap()
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons["readerPageButton"].value as? String, "Current page 1 of 3")
        app.swipeLeft()
        expectation(for: NSPredicate(format: "value == %@", "Current page 2 of 3"),
                    evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 5)
        app.buttons["readerPages"].tap()
        XCTAssertTrue(app.buttons["thumbnail_2"].waitForExistence(timeout: 10))
        app.buttons["thumbnail_2"].tap()
        expectation(for: NSPredicate(format: "value == %@", "Current page 3 of 3"), evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 5)
        app.buttons["readerPageButton"].tap()
        let jump = app.textFields["pageNumberInput"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        XCTAssertTrue(app.frame.contains(jump.frame))
        jump.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        confirmPageJump(in: app)
        expectation(for: NSPredicate(format: "value == %@", "Current page 2 of 3"), evaluatedWith: app.buttons["readerPageButton"])
        waitForExpectations(timeout: 5)
        app.buttons["readerSettings"].tap()
        XCTAssertTrue(app.switches["Show page slider"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["clearArchives"].exists)
        app.buttons["readerSettingsDone"].tap()
        app.buttons["readerHide"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["readerClose"])
        waitForExpectations(timeout: 5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["readerClose"].waitForExistence(timeout: 5))
        app.buttons["readerClose"].tap()
        XCTAssertTrue(app.buttons["openArchive"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["searchArchives"].exists)
        // The refreshed shared row follows the native progress flush and lease release.
        XCTAssertTrue(app.staticTexts["67% read"].waitForExistence(timeout: 10))
        let library = XCTAttachment(screenshot: app.screenshot())
        library.name = "Shared library after reader saved page 2"
        library.lifetime = .keepAlways
        add(library)

        app.terminate()
        // Reuse the disposable cache, but do not inject or import the fixture again.
        let relaunched = try launch(id: id)
        XCTAssertTrue(relaunched.staticTexts["67% read"].waitForExistence(timeout: 30))
        let resume = relaunched.buttons["Resume reading"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        XCTAssertTrue(relaunched.buttons["readerClose"].waitForExistence(timeout: 30))
        XCTAssertEqual(relaunched.buttons["readerPageButton"].value as? String, "Current page 2 of 3")
        XCTAssertFalse(relaunched.secureTextFields["passwordInput"].exists)
        let reader = XCTAttachment(screenshot: relaunched.screenshot())
        reader.name = "Shared reader resumed page 2 after restart"
        reader.lifetime = .keepAlways
        add(reader)
    }
}
