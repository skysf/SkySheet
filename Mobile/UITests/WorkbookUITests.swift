import XCTest

final class WorkbookUITests: XCTestCase {
    @MainActor func testPrepareFileUsingSystemProvider() {
        continueAfterFailure = false
        let source = XCUIApplication(bundleIdentifier: "ai.skylu.skyfolio.tests.filesource")
        source.launch()
        source.buttons["export-sample"].tap()
        let save = source.buttons["Save"]
        XCTAssertTrue(save.wait(for: \.isHittable, toEqual: true, timeout: 45), source.debugDescription)
        save.tap()
        XCTAssertTrue(source.buttons["export-sample"].wait(for: \.label, toEqual: "Exported", timeout: 45), source.debugDescription)
        source.terminate()
    }

    @MainActor func testSelectExternalWorkbookFromFiles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-workbook"].tap()
        // iPad 上 Files 作为另一个进程加载，刚弹出时仍只能查到后面的 SkyFolio。
        let picker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "Browse View (Picker)", "DOC.")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 60), app.debugDescription)
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Exported Workbook")).firstMatch
        let local = app.cells.matching(NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad"])).firstMatch
        let source = app.cells.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Picker Samples")).firstMatch
        let downloads = app.cells.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Downloads")).firstMatch
        // Browse 可能先显示最近使用、位置列表或上次的子目录。每次导航后重新查看所在位置。
        let phoneBack = app.buttons["BackButton"]
        let padBack = app.buttons["DOC.navBarButton.backInHistory"]
        let browse = app.buttons["Browse"]
        var visitedSource = false
        var visitedDownloads = false
        for _ in 0..<8 {
            if file.wait(for: \.isHittable, toEqual: true, timeout: 5) { break }
            if !visitedSource, source.isHittable { visitedSource = true; source.tap() }
            else if !visitedDownloads, downloads.isHittable { visitedDownloads = true; downloads.tap() }
            else if phoneBack.isHittable, ["On My iPhone", "On My iPad"].contains(phoneBack.label) {
                phoneBack.tap()
            } else if padBack.isHittable, padBack.isEnabled,
                      ["SkyFolio, Actions Menu", "Picker Samples, Actions Menu", "Downloads, Actions Menu"].contains(where: { app.buttons[$0].exists }) {
                padBack.tap()
            } else if local.isHittable { local.tap() }
            else if browse.isHittable { browse.tap() }
        }
        XCTAssertTrue(file.wait(for: \.isHittable, toEqual: true, timeout: 40), app.debugDescription)
        file.tap()
        editExternalCSV(in: app)
    }

    @MainActor func testOpenDocumentURLWritesBackToOriginalCSV() throws {
        continueAfterFailure = false
        // 由 UI 测试进程持有原件，通过系统的打开文稿事件交给 SkyFolio。独立从原路径读回。
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        try Data("31,93\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = XCUIApplication()
        app.open(url)
        editExternalCSV(in: app)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: .newlines).filter { !$0.isEmpty }, ["31,93", ",47"])
    }

    @MainActor private func editExternalCSV(in app: XCUIApplication) {
        let input = app.textFields["formula-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertEqual(input.value as? String, "31")
        app.buttons["cell-B2"].tap()
        input.tap()
        input.typeText("47\n")
        XCTAssertTrue(app.staticTexts["save-status"].wait(for: \.label, toEqual: "Saved", timeout: 60), app.debugDescription)
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
        XCTAssertTrue(app.staticTexts["save-status"].wait(for: \.label, toEqual: "Saved", timeout: 60), app.debugDescription)
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
