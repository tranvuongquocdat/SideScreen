import XCTest
@testable import SideScreen

final class CodecLimitsTests: XCTestCase {
    func testBooxPanelClampsToFitAvcLimit() {
        // Boox Nova Air C panel: 1872x1404. AVC HW decoder max: 1920x1088.
        let r = CodecLimits.clampForAvc(width: 1872, height: 1404)
        XCTAssertEqual(r.width, 1440)
        XCTAssertEqual(r.height, 1088)
    }

    func testSizeWithinLimitIsUntouched() {
        let r = CodecLimits.clampForAvc(width: 1920, height: 1080)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 1080)
    }

    func testWideHiDpiPanelClamps() {
        // 2560x1600 (16:10): height is the binding constraint (1088/1600).
        let r = CodecLimits.clampForAvc(width: 2560, height: 1600)
        XCTAssertEqual(r.width, 1728)
        XCTAssertEqual(r.height, 1088)
    }

    func testWidthBindingClampDoesNotLosePixelsToTruncation() {
        // 2148x800: width binds (scale = 1920/2148). Without rounding,
        // Int(2148 * 1920/2148) truncates to 1919 -> 1904. Expect 1920.
        let r = CodecLimits.clampForAvc(width: 2148, height: 800)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 704)
    }

    func testSmallPanelUntouched() {
        let r = CodecLimits.clampForAvc(width: 1280, height: 800)
        XCTAssertEqual(r.width, 1280)
        XCTAssertEqual(r.height, 800)
    }

    func testClampedDimensionsAre16Aligned() {
        let r = CodecLimits.clampForAvc(width: 3840, height: 2400)
        XCTAssertEqual(r.width % 16, 0)
        XCTAssertEqual(r.height % 16, 0)
        XCTAssertLessThanOrEqual(r.width, 1920)
        XCTAssertLessThanOrEqual(r.height, 1088)
    }
}
