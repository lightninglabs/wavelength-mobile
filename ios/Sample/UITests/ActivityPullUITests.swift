import XCTest

final class ActivityPullUITests: XCTestCase {
    func testReachingBottomWaitsForAnUpwardPull() {
        let app = XCUIApplication()
        app.launchArguments = ["--activity-pull-test"]
        app.launch()

        let scroll = app.scrollViews["test.activity.scroll"]
        let last = app.staticTexts["Entry 29"]
        let count = app.staticTexts["test.activity.count"]
        app.buttons["Show oldest loaded entry"].tap()
        let atEnd = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: last)
        wait(for: [atEnd], timeout: 5)
        XCTAssertEqual(count.label, "30 entries")

        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        let appended = expectation(for: NSPredicate(format: "label == %@", "60 entries"), evaluatedWith: count)
        wait(for: [appended], timeout: 5)
        XCTAssertTrue(last.isHittable, "Appending a page moved the reader away from the old tail")
    }
}
