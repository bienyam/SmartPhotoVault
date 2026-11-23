import XCTest
@testable import SmartPhotoVault

final class DeviceTests: XCTestCase {
    func testIPadModelsSayIPad() {
        XCTAssertEqual(Device.name(forModel: "iPad13,4"), "iPad")
        XCTAssertEqual(Device.name(forModel: "iPad16,6"), "iPad")
    }

    func testEverythingElseSaysIPhone() {
        XCTAssertEqual(Device.name(forModel: "iPhone17,2"), "iPhone")
        XCTAssertEqual(Device.name(forModel: "arm64"), "iPhone")
    }

    func testTheRunningDeviceIsNamed() {
        XCTAssertTrue(["iPhone", "iPad"].contains(Device.name))
    }
}
