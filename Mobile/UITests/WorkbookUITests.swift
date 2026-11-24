import XCTest

final class WorkbookUITests: XCTestCase {
    @MainActor func testEditReopenAndRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        func awaitValue(_ value: String, of element: XCUIElement) -> Bool {
            let expected = NSPredicate { _, _ in (element.value as? String ?? "") == value }
            return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: element)], timeout: 10) == .completed
        }
        app.buttons["open-workbook"].tap()
        // 文件在模拟器本机的 Files 文档提供方，使用正式的系统选择器。
        let service = XCUIApplication(bundleIdentifier: "com.apple.DocumentManager.DocumentManagerService")
        func item(_ name: String, in process: XCUIApplication) -> XCUIElement {
            process.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@ OR label BEGINSWITH %@",
                                                                   name, name + ".xlsx", name + ",")).firstMatch
        }
        var file = item("Arithmetic", in: app)
        if !file.waitForExistence(timeout: 8) { file = item("Arithmetic", in: service) }
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription)
        file.tap()
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
