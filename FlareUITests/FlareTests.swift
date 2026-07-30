//
//  MSJobMonitorUITests.swift
//  MSJobMonitorUITests
//
//  Created by Dan Chernopolskii on 8/18/25.
//

import XCTest

final class MSJobMonitorUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testPrimaryNavigation() throws {
        let app = XCUIApplication()
        app.launch()

        let showSidebarButton = app.buttons["sidebar.show"]
        if showSidebarButton.waitForExistence(timeout: 1) {
            showSidebarButton.click()
        }

        let jobsButton = app.buttons["sidebar.jobs"]
        XCTAssertTrue(jobsButton.waitForExistence(timeout: 5))

        app.buttons["sidebar.job-boards"].click()
        XCTAssertTrue(app.staticTexts["Job Boards"].waitForExistence(timeout: 3))

        app.buttons["sidebar.settings"].click()
        XCTAssertTrue(app.buttons["settings.check-for-updates"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
