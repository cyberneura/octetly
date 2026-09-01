import XCTest
@testable import Octetly

final class OctetlyTests: XCTestCase {
    func testDeviceIdentityUsesIPv4() {
        let device = Device(ipv4: "192.168.1.2")
        XCTAssertEqual(device.id, "192.168.1.2")
    }
}
