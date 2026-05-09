import XCTest
@testable import SideScreen

final class LANAddressResolverTests: XCTestCase {
    func testReturnsValidIPv4WhenOnNetwork() {
        guard let ip = LANAddressResolver.primaryIPv4() else { return }
        let parts = ip.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
        for p in parts {
            let n = Int(p)
            XCTAssertNotNil(n)
            XCTAssertGreaterThanOrEqual(n!, 0)
            XCTAssertLessThanOrEqual(n!, 255)
        }
        XCTAssertNotEqual(ip, "127.0.0.1", "Must skip loopback")
    }

    func testIsLoopbackHelper() {
        XCTAssertTrue(LANAddressResolver.isLoopback("127.0.0.1"))
        XCTAssertTrue(LANAddressResolver.isLoopback("::1"))
        XCTAssertFalse(LANAddressResolver.isLoopback("192.168.1.42"))
        XCTAssertFalse(LANAddressResolver.isLoopback("10.0.0.5"))
    }

    func testIsLinkLocalHelper() {
        XCTAssertTrue(LANAddressResolver.isLinkLocal("169.254.1.1"))
        XCTAssertFalse(LANAddressResolver.isLinkLocal("192.168.1.42"))
    }
}
