import XCTest

@MainActor
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testScreenshot01_ISS() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments = ["--screenshot", "01-iss"]
        app.launch()
        sleep(2)
        snapshot("01-iss")
    }

    func testScreenshot02_Moon() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments = ["--screenshot", "02-moon"]
        app.launch()
        sleep(2)
        snapshot("02-moon")
    }

    func testScreenshot03_Sydney() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments = ["--screenshot", "03-sydney"]
        app.launch()
        sleep(2)
        snapshot("03-sydney")
    }

    func testScreenshot04_Picker() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments = ["--screenshot", "04-picker"]
        app.launch()
        sleep(3)
        snapshot("04-picker")
    }
}
