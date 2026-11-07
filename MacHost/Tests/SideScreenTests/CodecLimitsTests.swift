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

    // MARK: - Client decoder limit clamp (issue #41)

    func testHiDpiStreamClampsToClientDecoderLimit() {
        // rm2109cmyk's case: 1200x720 HiDPI = 2400x1440 physical, budget
        // tablet decoder caps around 2048x1152.
        let r = CodecLimits.clamp(width: 2400, height: 1440, maxWidth: 2048, maxHeight: 1152)
        XCTAssertLessThanOrEqual(r.width, 2048)
        XCTAssertLessThanOrEqual(r.height, 1152)
        XCTAssertEqual(r.width % 16, 0)
        XCTAssertEqual(r.height % 16, 0)
    }

    func testStreamWithinClientLimitIsUntouched() {
        let r = CodecLimits.clamp(width: 1920, height: 1200, maxWidth: 4096, maxHeight: 2304)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 1200)
    }

    // MARK: - Frame-rate scaling of the client limit

    func testLimitIsUnchangedAtOrBelowReferenceRate() {
        let limit = (width: 2304, height: 1440)
        XCTAssertTrue(CodecLimits.scaleLimit(limit, forFps: 60) == limit)
        XCTAssertTrue(CodecLimits.scaleLimit(limit, forFps: 30) == limit)
    }

    func testLimitAreaHalvesAtDoubleRate() {
        let r = CodecLimits.scaleLimit((width: 2304, height: 1440), forFps: 120)
        // sqrt(0.5) per side => ~1629x1018, floored to 16 => 1616x1008
        XCTAssertEqual(r.width, 1616)
        XCTAssertEqual(r.height, 1008)
        let areaRatio = Double(r.width * r.height) / Double(2304 * 1440)
        XCTAssertEqual(areaRatio, 0.5, accuracy: 0.03)
        XCTAssertEqual(r.width % 16, 0)
        XCTAssertEqual(r.height % 16, 0)
    }

    func testScaledLimitKeepsAspect() {
        let r = CodecLimits.scaleLimit((width: 2560, height: 1600), forFps: 90)
        XCTAssertEqual(Double(r.width) / Double(r.height), 1.6, accuracy: 0.02)
    }

    // MARK: - Orientation-aware client limit

    func testPortraitCaptureIsMeasuredAgainstTransposedLimit() {
        // A portrait virtual display against a landscape-reported ceiling. Without
        // transposing, 1440x2304 would shrink to 900x1440 despite the client
        // displaying 1440x2304 natively.
        let r = CodecLimits.clampToClientLimit(width: 1440, height: 2304, limit: (width: 2304, height: 1440))
        XCTAssertEqual(r.width, 1440)
        XCTAssertEqual(r.height, 2304)
    }

    func testLandscapeCaptureUsesLimitAsReported() {
        let r = CodecLimits.clampToClientLimit(width: 2304, height: 1440, limit: (width: 2304, height: 1440))
        XCTAssertEqual(r.width, 2304)
        XCTAssertEqual(r.height, 1440)
    }

    func testTransposedLimitStillClampsOversizeCapture() {
        // HiDPI portrait: 2880x4608 physical against the same landscape ceiling.
        let r = CodecLimits.clampToClientLimit(width: 2880, height: 4608, limit: (width: 2304, height: 1440))
        XCTAssertLessThanOrEqual(r.width, 1440)
        XCTAssertLessThanOrEqual(r.height, 2304)
        XCTAssertEqual(r.width % 16, 0)
        XCTAssertEqual(r.height % 16, 0)
    }

    func testSquareCaptureIsUnaffectedByTransposition() {
        let r = CodecLimits.clampToClientLimit(width: 1600, height: 1600, limit: (width: 2304, height: 1440))
        XCTAssertLessThanOrEqual(r.height, 1440)
        XCTAssertEqual(r.width, r.height)
    }

    func testClientLimitPreservesAspectRatio() {
        let r = CodecLimits.clamp(width: 3840, height: 2400, maxWidth: 1920, maxHeight: 1920)
        // 16:10 in, ~16:10 out (within 16-alignment error)
        let aspectIn = Double(3840) / Double(2400)
        let aspectOut = Double(r.width) / Double(r.height)
        XCTAssertEqual(aspectIn, aspectOut, accuracy: 0.05)
        XCTAssertLessThanOrEqual(r.width, 1920)
    }

    // MARK: - Per-rate limit table (issue #78)

    private let honorPadX9: [Int: (width: Int, height: Int)] = [
        30: (width: 2000, height: 1200),
        60: (width: 1744, height: 1040),
        120: (width: 1248, height: 752),
    ]

    func testTableEntryAtTheStreamRateIsUsed() {
        let r = CodecLimits.budget(limit: (width: 1744, height: 1040), table: honorPadX9, forFps: 30)
        XCTAssertEqual(r?.width, 2000)
        XCTAssertEqual(r?.height, 1200)
    }

    func testMeasuredEntryBeatsTheSingleLimit() {
        let r = CodecLimits.budget(limit: (width: 1744, height: 1040), table: honorPadX9, forFps: 60)
        XCTAssertEqual(r?.width, 1744)
        XCTAssertEqual(r?.height, 1040)
    }

    func testRateBetweenEntriesRoundsUpToTheNextMeasuredRate() {
        let r = CodecLimits.budget(limit: nil, table: honorPadX9, forFps: 90)
        XCTAssertEqual(r?.width, 1248)
        XCTAssertEqual(r?.height, 752)
    }

    func testRateAboveTheTableScalesItsFastestEntryByArea() {
        let r = CodecLimits.budget(limit: nil, table: honorPadX9, forFps: 240)!
        let areaRatio = Double(r.width * r.height) / Double(1248 * 752)
        XCTAssertEqual(areaRatio, 0.5, accuracy: 0.05)
        XCTAssertEqual(r.width % 16, 0)
        XCTAssertEqual(r.height % 16, 0)
    }

    func testPanelSizedLimitIsNotScaledWhenTheTableSaysTheRateIsFine() {
        // CryoLogicat's MatePad Air (#78): the 60 fps limit was the panel itself,
        // and the old scaling halved its area at 120 Hz although the decoder had
        // budget to spare. A measured 120 fps entry keeps the panel.
        let panel = (width: 2800, height: 1840)
        let table = [30: panel, 60: panel, 120: panel]
        let r = CodecLimits.budget(limit: panel, table: table, forFps: 120)!
        let enc = CodecLimits.clampToClientLimit(width: 2800, height: 1840, limit: r)
        XCTAssertEqual(enc.width, 2800)
        XCTAssertEqual(enc.height, 1840)
    }

    func testWithoutATableTheSingleLimitScalesAsBefore() {
        // The exact figure reported in #78: 2800x1840 at 120 Hz became 1968x1280.
        let panel = (width: 2800, height: 1840)
        let r = CodecLimits.budget(limit: panel, table: nil, forFps: 120)!
        XCTAssertEqual(r.width, 1968)
        XCTAssertEqual(r.height, 1296)
        let enc = CodecLimits.clampToClientLimit(width: 2800, height: 1840, limit: r)
        XCTAssertEqual(enc.width, 1968)
        XCTAssertEqual(enc.height, 1280)
    }

    func testNothingReportedGivesNoBudget() {
        XCTAssertNil(CodecLimits.budget(limit: nil, table: nil, forFps: 60))
        XCTAssertNil(CodecLimits.budget(limit: nil, table: [:], forFps: 60))
    }

    // MARK: - Panel sides that are not multiples of 16

    func testHiDpiCaptureOfANativePanelKeepsTheExactPanelSize() {
        // Xiaomi Pad 6: 2880x1800 panel, HiDPI capture at 5760x3600. Flooring
        // to 16 gave 2880x1792 (and 2864x1792 once that became the limit).
        let r = CodecLimits.clamp(width: 5760, height: 3600, maxWidth: 2880, maxHeight: 1800)
        XCTAssertEqual(r.width, 2880)
        XCTAssertEqual(r.height, 1800)
    }

    func testTenEightyPanelKeepsItsRows() {
        // 2340x1080 phone (the LG V510N from #88), HiDPI capture.
        let r = CodecLimits.clamp(width: 4680, height: 2160, maxWidth: 2340, maxHeight: 1080)
        XCTAssertEqual(r.width, 2340)
        XCTAssertEqual(r.height, 1080)
    }

    func testPortraitCaptureOfANativePanelKeepsTheExactPanelSize() {
        let r = CodecLimits.clampToClientLimit(width: 3600, height: 5760, limit: (width: 2880, height: 1800))
        XCTAssertEqual(r.width, 1800)
        XCTAssertEqual(r.height, 2880)
    }

    func testExactFitIsKeptEven() {
        let r = CodecLimits.clamp(width: 2002, height: 1202, maxWidth: 1001, maxHeight: 601)
        XCTAssertEqual(r.width, 1000)
        XCTAssertEqual(r.height, 600)
    }

    func testOlderClientsSixteenAlignedLimitStillFloors() {
        // A client that predates the fix reports 2880x1792 for the same
        // panel. The aspect no longer matches, so the 16-aligned fit applies.
        let r = CodecLimits.clamp(width: 5760, height: 3600, maxWidth: 2880, maxHeight: 1792)
        XCTAssertEqual(r.width, 2864)
        XCTAssertEqual(r.height, 1792)
    }

    func testAspectMismatchStillFloorsToSixteen() {
        let r = CodecLimits.clamp(width: 5760, height: 3600, maxWidth: 2340, maxHeight: 1080)
        XCTAssertEqual(r.width % 16, 0)
        XCTAssertEqual(r.height % 16, 0)
        XCTAssertLessThanOrEqual(r.width, 2340)
        XCTAssertLessThanOrEqual(r.height, 1080)
    }
}
