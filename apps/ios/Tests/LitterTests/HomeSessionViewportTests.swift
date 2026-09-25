import XCTest
import CoreGraphics
@testable import Litter

final class HomeSessionViewportTests: XCTestCase {
    func testVariableHeightRowsMatchLinearIntersectionAtEveryOffset() {
        var y: CGFloat = 0
        let frames = (0..<1_000).map { index in
            let height = CGFloat(20 + index % 110)
            defer { y += height }
            return CGRect(x: 0, y: y, width: 390, height: height)
        }
        for offset in stride(from: -800, through: Int(y) + 800, by: 137) {
            let viewport = CGRect(x: 0, y: offset, width: 390, height: 800)
            let expected = frames.indices.filter {
                frames[$0].maxY > viewport.minY && frames[$0].minY < viewport.maxY
            }
            XCTAssertEqual(Array(HomeSessionViewport.visibleRange(in: frames, viewport: viewport)), expected)
        }
    }

    func testEmptyAndBoundaryViewports() {
        let frames = (0..<3).map { CGRect(x: 0, y: $0 * 50, width: 390, height: 50) }
        XCTAssertEqual(HomeSessionViewport.visibleRange(in: [], viewport: .zero), 0..<0)
        XCTAssertEqual(HomeSessionViewport.visibleRange(in: frames, viewport: CGRect(x: 0, y: 50, width: 390, height: 50)), 1..<2)
        XCTAssertEqual(HomeSessionViewport.visibleRange(in: frames, viewport: CGRect(x: 0, y: 150, width: 390, height: 50)), 3..<3)
        XCTAssertNil(HomeSessionViewport.anchor(in: frames, at: -1))
        XCTAssertEqual(HomeSessionViewport.anchor(in: frames, at: 75)?.0, 1)
        XCTAssertEqual(HomeSessionViewport.anchor(in: frames, at: 75)?.1, 0.5)
        XCTAssertEqual(HomeSessionViewport.anchor(in: frames, at: 150)?.0, 2)
        XCTAssertEqual(HomeSessionViewport.anchor(in: frames, at: 150)?.1, 1)
    }

    func testLargeListViewportLookupPerformance() {
        let frames = (0..<100_000).map { CGRect(x: 0, y: $0 * 54, width: 390, height: 54) }
        measure {
            for index in 0..<1_000 {
                let range = HomeSessionViewport.visibleRange(
                    in: frames, viewport: CGRect(x: 0, y: index * 5_000, width: 390, height: 2_400)
                )
                XCTAssertLessThanOrEqual(range.count, 46)
            }
        }
    }
}
