import XCTest

/// Walks through the app against a demo device and saves the README screenshots.
///
/// Set up (see docs/SCREENSHOTS.md): an Android TV emulator reachable at $DEMO_HOST
/// (default living-room-tv.local) port 5555, a few photos in the simulator's library, then:
///   SCREENSHOT_DIR=docs/screenshots/ios xcodebuild test -scheme AdbRemote \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AdbRemoteUITests
final class Screenshots: XCTestCase {
    let app = XCUIApplication()

    var env: [String: String] { ProcessInfo.processInfo.environment }
    var dir: String { env["SCREENSHOT_DIR"] ?? "/tmp/shots" }
    var host: String { env["DEMO_HOST"] ?? "living-room-tv.local" }
    var demoName: String { env["DEMO_NAME"] ?? "Living Room TV" }

    func shot(_ file: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(dir)/\(file).png"))
    }

    override func setUp() {
        continueAfterFailure = false
        // Photo library and local network prompts.
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    /// Adds the demo device if it isn't there yet and waits for it to connect.
    func connect() {
        app.launch()
        app.tabBars.buttons["Devices"].tap()
        if !app.staticTexts[demoName].waitForExistence(timeout: 3) {
            app.buttons["Add Device"].firstMatch.tap()
            app.textFields["Name (optional)"].tap()
            app.typeText(demoName)
            app.textFields["IP address"].tap()
            app.typeText(host)
            app.buttons["Connect"].tap()
        }
        // Connected devices show their delay ("Delay 2 milliseconds" to VoiceOver).
        let latency = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Delay '")).firstMatch
        XCTAssertTrue(latency.waitForExistence(timeout: 30))
    }

    func testReadmeScreenshots() throws {
        connect()
        sleep(2)
        shot("devices")
        app.staticTexts[demoName].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["What Works on This TV"].waitForExistence(timeout: 20))
        shot("device-details")

        app.tabBars.buttons["Control"].tap()
        app.buttons["Buttons"].tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 20))
        sleep(2)
        shot("remote")
        app.buttons["Trackpad"].tap()
        sleep(2)
        shot("trackpad")
        app.buttons["Screen"].tap()
        sleep(8)
        shot("screen")
        app.buttons["Buttons"].tap()

        app.tabBars.buttons["Play"].tap()
        app.buttons["Photos"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Photo"].firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        shot("play-photos")
        app.descendants(matching: .any).matching(identifier: "Photo").element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["On the TV"].waitForExistence(timeout: 60))
        sleep(1)
        shot("play-viewer")
        app.buttons["Done"].tap()
        sleep(1)
        app.buttons["Link"].tap()
        sleep(1)
        shot("play-link")
        app.buttons["Mirror"].tap()
        sleep(3)
        shot("play-mirror")
        app.buttons["Photos"].tap()

        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 30))
        sleep(3)
        shot("apps")
        app.staticTexts["Settings"].press(forDuration: 1.2)
        sleep(1)
        shot("apps-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()

        app.tabBars.buttons["Files"].tap()
        XCTAssertTrue(app.staticTexts["Download"].waitForExistence(timeout: 20))
        sleep(1)
        shot("files")
    }
}
