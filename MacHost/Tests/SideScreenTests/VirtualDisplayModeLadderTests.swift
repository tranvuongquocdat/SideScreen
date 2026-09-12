import XCTest
@testable import SideScreen

final class VirtualDisplayModeLadderTests: XCTestCase {
    func testLadderStartsAtChosenSize() {
        let ladder = VirtualDisplayManager.hiDPILogicalLadder(width: 2304, height: 1440)
        XCTAssertEqual(ladder.first?.width, 2304)
        XCTAssertEqual(ladder.first?.height, 1440)
    }

    func testLadderGivesMacOSEnoughRungsToDrawItsPicker() {
        // A single logical mode leaves System Settings with no scaling control at all.
        let ladder = VirtualDisplayManager.hiDPILogicalLadder(width: 2304, height: 1440)
        XCTAssertGreaterThanOrEqual(ladder.count, 5)
    }

    func testEveryRungKeepsTheChosenAspectRatio() {
        // A rung off the panel's aspect letterboxes on the client.
        for (w, h) in [(2304, 1440), (1920, 1200), (2560, 1440), (1024, 768)] {
            let aspect = Double(w) / Double(h)
            for rung in VirtualDisplayManager.hiDPILogicalLadder(width: w, height: h) {
                let rungAspect = Double(rung.width) / Double(rung.height)
                XCTAssertEqual(rungAspect, aspect, accuracy: 0.01, "rung \(rung.width)x\(rung.height) for \(w)x\(h)")
            }
        }
    }

    func testRungsDescendAndAreUnique() {
        let ladder = VirtualDisplayManager.hiDPILogicalLadder(width: 2304, height: 1440)
        let widths = ladder.map(\.width)
        XCTAssertEqual(widths, widths.sorted(by: >))
        XCTAssertEqual(Set(widths).count, widths.count)
    }

    func testRungsAreEvenSoThePhysicalModeIsWhole() {
        for rung in VirtualDisplayManager.hiDPILogicalLadder(width: 2304, height: 1440) {
            XCTAssertEqual(rung.width % 2, 0)
            XCTAssertEqual(rung.height % 2, 0)
        }
    }

    func testKnownLadderForTabletPanel() {
        let ladder = VirtualDisplayManager.hiDPILogicalLadder(width: 2304, height: 1440)
        let rendered = ladder.map { "\($0.width)x\($0.height)" }
        XCTAssertEqual(rendered, ["2304x1440", "2016x1260", "1728x1080", "1440x900", "1152x720"])
    }

    func testTinyResolutionCollapsesDuplicatesInsteadOfRepeating() {
        let ladder = VirtualDisplayManager.hiDPILogicalLadder(width: 32, height: 20)
        XCTAssertEqual(Set(ladder.map { "\($0.width)x\($0.height)" }).count, ladder.count)
    }

    func testZeroSizeYieldsNoRungs() {
        XCTAssertTrue(VirtualDisplayManager.hiDPILogicalLadder(width: 0, height: 0).isEmpty)
    }
}
