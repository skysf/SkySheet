import XCTest

final class WorkbookUITests: XCTestCase {
    @MainActor func testBrowseFilesAndOpenCSV() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-workbook"].tap()
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "From Files")).firstMatch
        if !file.waitForExistence(timeout: 5) {
            let browse = app.buttons["Browse"]
            if browse.isHittable { browse.tap() }
            let local = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad"])).firstMatch
            if local.waitForExistence(timeout: 5), local.isHittable { local.tap() }
            let folder = app.cells.containing(.staticText, identifier: "SkyFolio").firstMatch
            if folder.waitForExistence(timeout: 5), folder.isHittable { folder.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 15), app.debugDescription)
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.23)).tap()
        let input = app.textFields["formula-input"]
        if !input.waitForExistence(timeout: 5) {
            let confirm = app.buttons["Open"].firstMatch
            if confirm.isHittable { confirm.tap() }
            else if file.isHittable { file.doubleTap() }
        }
        XCTAssertTrue(input.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(input.value as? String, "31")
        app.terminate()
    }

    @MainActor func testEditReopenAndRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        func awaitValue(_ value: String, of element: XCUIElement) -> Bool {
            let expected = value.isEmpty ? NSPredicate(format: "value == nil OR value == ''") : NSPredicate(format: "value == %@", value)
            return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: element)], timeout: 10) == .completed
        }
        app.buttons["file-Arithmetic.xlsx"].tap()
        let input = app.textFields["formula-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("7\n")
        let b1 = app.buttons["cell-B1"]
        XCTAssertTrue(b1.waitForExistence(timeout: 5))
        b1.tap()
        input.tap()
        input.typeText("=A1*3\n")
        XCTAssertTrue(awaitValue("21", of: b1))
        XCTAssertTrue(app.staticTexts["save-status"].wait(for: \.label, toEqual: "Saved", timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "SkyFolio Workbook"
        shot.lifetime = .keepAlways
        add(shot)
        // 直接结束再启动，既没有压保存按钮，也没有让关窗逻辑替测试保存。
        app.terminate()
        app.launch()
        app.buttons["file-Arithmetic.xlsx"].tap()
        XCTAssertTrue(b1.waitForExistence(timeout: 10))
        XCTAssertEqual(b1.value as? String, "21")
        b1.tap()
        XCTAssertEqual(input.value as? String, "=A1*3")
        app.buttons["workbook-options"].tap()
        app.buttons["Version History"].tap()
        app.buttons["Restore Edit Sheet1!A1"].tap()
        XCTAssertTrue(awaitValue("", of: b1))
        XCTAssertEqual(app.buttons["cell-A1"].value as? String, "7")
        app.buttons["close-workbook"].tap()
        app.buttons["file-Arithmetic.xlsx"].tap()
        XCTAssertTrue(b1.waitForExistence(timeout: 10))
        XCTAssertTrue((b1.value as? String ?? "").isEmpty)
    }
}
