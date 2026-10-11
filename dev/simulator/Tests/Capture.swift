// Native Simulator capture regression, followed by matching-artifact replay on the Mac.
import XCTest

final class Capture: XCTestCase {
    func testCaptureFromSimulator() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.gleamdream.retrace.example")
        app.launch()
        let increment = app.buttons["Add a point"]
        XCTAssertTrue(increment.waitForExistence(timeout: 30), app.debugDescription)
        increment.tap()
        Thread.sleep(forTimeInterval: 3) // Preserve this idle gap in browser playback.
        let unchanged = app.buttons["Record an unchanged state"]
        for _ in 0..<5 {
            if unchanged.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(unchanged.isHittable, app.debugDescription)
        unchanged.tap()
        let device = app.buttons["Read device information"]
        for _ in 0..<5 {
            if device.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(device.isHittable, app.debugDescription)
        device.tap()
        let nativeResult = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ios / aarch64")).firstMatch
        XCTAssertTrue(nativeResult.waitForExistence(timeout: 15), app.debugDescription)
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Details")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Card details"].waitForExistence(timeout: 5))
        app.buttons["Back to card"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("SIMULATOR_CAPTURE_UI_PASSED")
    }
}
