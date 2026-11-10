import CoreGraphics
import XCTest
@testable import FrameStackCore

final class CropEditingTests: XCTestCase {
    private let hd = PixelSize(width: 1920, height: 1080)
    private let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func assertInside(_ r: CGRect, _ canvas: PixelSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(r.minX, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.minY, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxX, Double(canvas.width), file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY, Double(canvas.height), file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.width, 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.height, 1, file: file, line: line)
        for v in [r.minX, r.minY, r.width, r.height] { XCTAssertEqual(v, v.rounded(), "whole pixels", file: file, line: line) }
    }

    // MARK: Free drags

    func testFreeEdgesAndCornersMoveOnlyTheirOwnSides() {
        let start = CGRect(x: 200, y: 100, width: 800, height: 600)
        XCTAssertEqual(CropEditing.drag(start, handle: .left, by: CGSize(width: 50, height: 999), canvas: hd), CGRect(x: 250, y: 100, width: 750, height: 600))
        XCTAssertEqual(CropEditing.drag(start, handle: .right, by: CGSize(width: -50, height: 999), canvas: hd), CGRect(x: 200, y: 100, width: 750, height: 600))
        XCTAssertEqual(CropEditing.drag(start, handle: .top, by: CGSize(width: 999, height: -40), canvas: hd), CGRect(x: 200, y: 60, width: 800, height: 640))
        XCTAssertEqual(CropEditing.drag(start, handle: .bottom, by: CGSize(width: 999, height: 40), canvas: hd), CGRect(x: 200, y: 100, width: 800, height: 640))
        XCTAssertEqual(CropEditing.drag(start, handle: .topLeft, by: CGSize(width: -20, height: 30), canvas: hd), CGRect(x: 180, y: 130, width: 820, height: 570))
        XCTAssertEqual(CropEditing.drag(start, handle: .bottomRight, by: CGSize(width: 100.4, height: -99.6), canvas: hd), CGRect(x: 200, y: 100, width: 900, height: 500))
        XCTAssertEqual(CropEditing.drag(start, handle: .topRight, by: CGSize(width: 10, height: 10), canvas: hd), CGRect(x: 200, y: 110, width: 810, height: 590))
        XCTAssertEqual(CropEditing.drag(start, handle: .bottomLeft, by: CGSize(width: 10, height: 10), canvas: hd), CGRect(x: 210, y: 100, width: 790, height: 610))
    }

    func testFreeDragsStopAtTheCanvasAndAtTheMinimumSide() {
        let start = CGRect(x: 200, y: 100, width: 800, height: 600)
        XCTAssertEqual(CropEditing.drag(start, handle: .left, by: CGSize(width: -5000, height: 0), canvas: hd), CGRect(x: 0, y: 100, width: 1000, height: 600))
        XCTAssertEqual(CropEditing.drag(start, handle: .bottomRight, by: CGSize(width: 5000, height: 5000), canvas: hd), CGRect(x: 200, y: 100, width: 1720, height: 980))
        // Dragged past the opposite side: it stops 16 px short instead of flipping.
        XCTAssertEqual(CropEditing.drag(start, handle: .left, by: CGSize(width: 5000, height: 0), canvas: hd), CGRect(x: 984, y: 100, width: 16, height: 600))
        XCTAssertEqual(CropEditing.drag(start, handle: .top, by: CGSize(width: 0, height: 5000), canvas: hd), CGRect(x: 200, y: 684, width: 800, height: 16))
        XCTAssertEqual(CropEditing.drag(start, handle: .bottomRight, by: CGSize(width: -5000, height: -5000), canvas: hd), CGRect(x: 200, y: 100, width: 16, height: 16))
        // A tiny canvas has a smaller minimum.
        XCTAssertEqual(CropEditing.minimumSide(for: PixelSize(width: 8, height: 400)), 8)
        // A crop already thinner than the minimum (typed into the fields) is not forced wider.
        let thin = CGRect(x: 10, y: 10, width: 4, height: 300)
        XCTAssertEqual(CropEditing.drag(thin, handle: .left, by: CGSize(width: 100, height: 0), canvas: hd), thin)
    }

    func testBodyMovesWithoutResizingAndStaysInside() {
        let start = CGRect(x: 200, y: 100, width: 800, height: 600)
        XCTAssertEqual(CropEditing.drag(start, handle: .body, by: CGSize(width: 33.4, height: -20.6), canvas: hd), CGRect(x: 233, y: 79, width: 800, height: 600))
        XCTAssertEqual(CropEditing.drag(start, handle: .body, by: CGSize(width: 9000, height: 9000), canvas: hd), CGRect(x: 1120, y: 480, width: 800, height: 600))
        XCTAssertEqual(CropEditing.drag(start, handle: .body, by: CGSize(width: -9000, height: -9000), canvas: hd), CGRect(x: 0, y: 0, width: 800, height: 600))
        // The body of a locked crop moves the same way.
        XCTAssertEqual(CropEditing.drag(start, handle: .body, by: CGSize(width: 10, height: 10), canvas: hd, aspect: 4.0 / 3), CGRect(x: 210, y: 110, width: 800, height: 600))
    }

    // MARK: Locked drags

    func testLockedCornerKeepsTheOppositeCornerAndTheRatio() {
        let start = CGRect(x: 400, y: 200, width: 800, height: 450)   // 16:9
        let a = 16.0 / 9
        // Widening by 160 px makes it 960×540 from the same top-left.
        XCTAssertEqual(CropEditing.drag(start, handle: .bottomRight, by: CGSize(width: 160, height: 0), canvas: hd, aspect: a), CGRect(x: 400, y: 200, width: 960, height: 540))
        // The pointer leads on whichever axis has gone furthest: 90 px down is 160 px across.
        XCTAssertEqual(CropEditing.drag(start, handle: .bottomRight, by: CGSize(width: 10, height: 90), canvas: hd, aspect: a), CGRect(x: 400, y: 200, width: 960, height: 540))
        // The top-left handle keeps the bottom-right corner (1200, 650).
        let tl = CropEditing.drag(start, handle: .topLeft, by: CGSize(width: -160, height: 0), canvas: hd, aspect: a)
        XCTAssertEqual(tl, CGRect(x: 240, y: 110, width: 960, height: 540))
        XCTAssertEqual(tl.maxX, 1200); XCTAssertEqual(tl.maxY, 650)
        let tr = CropEditing.drag(start, handle: .topRight, by: CGSize(width: 160, height: 0), canvas: hd, aspect: a)
        XCTAssertEqual(tr, CGRect(x: 400, y: 110, width: 960, height: 540))
        let bl = CropEditing.drag(start, handle: .bottomLeft, by: CGSize(width: -160, height: 0), canvas: hd, aspect: a)
        XCTAssertEqual(bl, CGRect(x: 240, y: 200, width: 960, height: 540))
    }

    func testLockedCornerStopsAtWhicheverCanvasEdgeComesFirst() {
        let a = 16.0 / 9
        // From (400, 200) there are 1520 px to the right and 880 px down: 880·16/9 = 1564 > 1520, so the width limits it.
        let big = CropEditing.drag(CGRect(x: 400, y: 200, width: 800, height: 450), handle: .bottomRight, by: CGSize(width: 9000, height: 9000), canvas: hd, aspect: a)
        XCTAssertEqual(big, CGRect(x: 400, y: 200, width: 1520, height: 855))
        // From (100, 700) only 380 px remain below: 380·16/9 = 675.6 → 676×380 (the nearest pixel).
        let low = CropEditing.drag(CGRect(x: 100, y: 700, width: 320, height: 180), handle: .bottomRight, by: CGSize(width: 9000, height: 9000), canvas: hd, aspect: a)
        XCTAssertEqual(low, CGRect(x: 100, y: 700, width: 676, height: 380))
        // Shrinking stops at the minimum: 16 px on the short side.
        let small = CropEditing.drag(CGRect(x: 400, y: 200, width: 800, height: 450), handle: .bottomRight, by: CGSize(width: -9000, height: -9000), canvas: hd, aspect: a)
        XCTAssertEqual(small, CGRect(x: 400, y: 200, width: 28, height: 16))
        // Portrait: the short side is the width.
        let portrait = CropEditing.drag(CGRect(x: 400, y: 200, width: 450, height: 800), handle: .bottomRight, by: CGSize(width: -9000, height: -9000), canvas: hd, aspect: 9.0 / 16)
        XCTAssertEqual(portrait, CGRect(x: 400, y: 200, width: 16, height: 28))
    }

    func testLockedEdgeKeepsTheOppositeEdgeAndStaysCentredOnTheOtherAxis() {
        let start = CGRect(x: 400, y: 200, width: 800, height: 450)   // centre y 425
        let a = 16.0 / 9
        let right = CropEditing.drag(start, handle: .right, by: CGSize(width: 160, height: 0), canvas: hd, aspect: a)
        XCTAssertEqual(right, CGRect(x: 400, y: 155, width: 960, height: 540))
        XCTAssertEqual(right.midY, 425)
        let left = CropEditing.drag(start, handle: .left, by: CGSize(width: -160, height: 0), canvas: hd, aspect: a)
        XCTAssertEqual(left, CGRect(x: 240, y: 155, width: 960, height: 540))
        // Bottom edge 90 px down: 540 high, 960 wide, centred on x 800.
        let bottom = CropEditing.drag(start, handle: .bottom, by: CGSize(width: 0, height: 90), canvas: hd, aspect: a)
        XCTAssertEqual(bottom, CGRect(x: 320, y: 200, width: 960, height: 540))
        let top = CropEditing.drag(start, handle: .top, by: CGSize(width: 0, height: -90), canvas: hd, aspect: a)
        XCTAssertEqual(top, CGRect(x: 320, y: 110, width: 960, height: 540))
        // Growing is limited by the room around the centre line: 425 px above → at most 850 high.
        let limited = CropEditing.drag(start, handle: .right, by: CGSize(width: 9000, height: 0), canvas: hd, aspect: a)
        XCTAssertEqual(limited, CGRect(x: 400, y: 0, width: 1511, height: 850))
    }

    func testLockedResultsAreTheRatioToTheNearestPixelForEveryHandleAndPreset() {
        let canvas = PixelSize(width: 1917, height: 1083)   // nothing divides evenly
        let start = CGRect(x: 311, y: 207, width: 640, height: 480)
        for preset in CropAspect.presets + CropAspect.presets.map({ $0.flipped(canvas: canvas) }) + [.original] {
            let a = preset.value(canvas: canvas)!
            let fitted = CropEditing.fit(start, toAspect: a, canvas: canvas)
            for handle in CropHandle.allCases {
                for delta in [CGSize(width: 37.3, height: -18.9), CGSize(width: -251, height: 140), CGSize(width: 4000, height: 4000), CGSize(width: -4000, height: -4000)] {
                    let r = CropEditing.drag(fitted, handle: handle, by: delta, canvas: canvas, aspect: a)
                    assertInside(r, canvas)
                    XCTAssertTrue(abs(r.width - r.height * a) <= 1 || abs(r.height - r.width / a) <= 1, "\(preset.id) \(handle) \(delta): \(r)")
                }
            }
        }
    }

    // MARK: Choosing a shape

    func testFitKeepsTheCentreAndTheAreaWhereTheCanvasAllows() {
        // 1080×1080 → 16:9 of the same area is 1440×810, same centre.
        let square = CGRect(x: 420, y: 0, width: 1080, height: 1080)
        XCTAssertEqual(CropEditing.fit(square, toAspect: 16.0 / 9, canvas: hd), CGRect(x: 240, y: 135, width: 1440, height: 810))
        // …and back: no shrinking from switching shapes.
        XCTAssertEqual(CropEditing.fit(CGRect(x: 240, y: 135, width: 1440, height: 810), toAspect: 1, canvas: hd), square)
        // The full 16:9 canvas held to 16:9 stays full; held to 1:1 it becomes the largest square, centred.
        XCTAssertEqual(CropEditing.fit(full, toAspect: 16.0 / 9, canvas: hd), full)
        XCTAssertEqual(CropEditing.fit(full, toAspect: 1, canvas: hd), square)
        // Portrait 9:16 of the full canvas: limited by the height.
        XCTAssertEqual(CropEditing.fit(full, toAspect: 9.0 / 16, canvas: hd), CGRect(x: 656, y: 0, width: 608, height: 1080))
        // A crop near a corner is moved inside rather than shrunk: 300×100 at the far right → 3:2 of the same area is 212×141.
        let corner = CropEditing.fit(CGRect(x: 1620, y: 980, width: 300, height: 100), toAspect: 1.5, canvas: hd)
        XCTAssertEqual(corner.size, CGSize(width: 212, height: 141))
        XCTAssertEqual(corner.maxY, 1080)
        XCTAssertEqual(corner.midX, 1770, accuracy: 0.5)
    }

    func testInscribedIsTheLargestCentredRectangleOfTheShapeInsideAnother() {
        let safe = CGRect(x: 100, y: 50, width: 1000, height: 900)
        XCTAssertEqual(CropEditing.inscribed(aspect: 1, in: safe, canvas: hd), CGRect(x: 150, y: 50, width: 900, height: 900))
        XCTAssertEqual(CropEditing.inscribed(aspect: 2, in: safe, canvas: hd), CGRect(x: 100, y: 250, width: 1000, height: 500))
        let r = CropEditing.inscribed(aspect: 16.0 / 9, in: CGRect(x: 7, y: 3, width: 1001, height: 777), canvas: hd)
        XCTAssertEqual(r.size, CGSize(width: 1001, height: 563))
        XCTAssertTrue(CGRect(x: 7, y: 3, width: 1001, height: 777).contains(r))
    }

    func testDrawingANewCropFromAnAnchor() {
        // Free: the rectangle between the two points, in any direction, clamped to the canvas.
        XCTAssertEqual(CropEditing.drawn(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 300), canvas: hd), CGRect(x: 100, y: 100, width: 400, height: 200))
        XCTAssertEqual(CropEditing.drawn(from: CGPoint(x: 500, y: 300), to: CGPoint(x: 100.4, y: 99.6), canvas: hd), CGRect(x: 100, y: 100, width: 400, height: 200))
        XCTAssertEqual(CropEditing.drawn(from: CGPoint(x: 1800, y: 1000), to: CGPoint(x: 5000, y: 5000), canvas: hd), CGRect(x: 1800, y: 1000, width: 120, height: 80))
        // A click or a tiny drag draws nothing.
        XCTAssertNil(CropEditing.drawn(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), canvas: hd))
        XCTAssertNil(CropEditing.drawn(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 110), canvas: hd))
        // Locked: the shape from the anchor, towards the pointer, limited by the canvas.
        XCTAssertEqual(CropEditing.drawn(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 420, y: 150), canvas: hd, aspect: 16.0 / 9), CGRect(x: 100, y: 100, width: 320, height: 180))
        XCTAssertEqual(CropEditing.drawn(from: CGPoint(x: 1000, y: 600), to: CGPoint(x: 680, y: 590), canvas: hd, aspect: 16.0 / 9), CGRect(x: 680, y: 420, width: 320, height: 180))
        XCTAssertEqual(CropEditing.drawn(from: CGPoint(x: 1000, y: 100), to: CGPoint(x: 3000, y: 90), canvas: hd, aspect: 16.0 / 9), CGRect(x: 1000, y: 0, width: 178, height: 100))
        XCTAssertNil(CropEditing.drawn(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 104), canvas: hd, aspect: 16.0 / 9))
    }

    // MARK: Shapes

    func testAspectValuesFlipsAndNames() {
        XCTAssertNil(CropAspect.free.value(canvas: hd))
        XCTAssertEqual(CropAspect.original.value(canvas: hd)!, 16.0 / 9, accuracy: 1e-12)
        XCTAssertEqual(CropAspect.ratio(3, 2).value(canvas: hd), 1.5)
        XCTAssertEqual(CropAspect.ratio(3, 2).flipped(canvas: hd), .ratio(2, 3))
        XCTAssertEqual(CropAspect.original.flipped(canvas: hd), .ratio(9, 16))
        XCTAssertEqual(CropAspect.original.flipped(canvas: PixelSize(width: 500, height: 500)), .original)
        XCTAssertFalse(CropAspect.free.canFlip(canvas: hd))
        XCTAssertFalse(CropAspect.ratio(1, 1).canFlip(canvas: hd))
        XCTAssertTrue(CropAspect.ratio(16, 9).canFlip(canvas: hd))
        XCTAssertEqual(CropAspect.presets.map(\.displayName), ["1 : 1", "5 : 4", "4 : 3", "3 : 2", "16 : 9", "2 : 1"])
        XCTAssertEqual(Set(([.free, .original] + CropAspect.presets).map(\.id)).count, 8)
        XCTAssertFalse(CropAspect.free.isLocked)
        XCTAssertTrue(CropAspect.original.isLocked)

        XCTAssertEqual(CropAspect.name(for: hd), "16 : 9")
        XCTAssertEqual(CropAspect.name(for: PixelSize(width: 1080, height: 1920)), "9 : 16")
        XCTAssertEqual(CropAspect.name(for: PixelSize(width: 608, height: 1080)), "9 : 16")   // 607.5 rounded
        XCTAssertEqual(CropAspect.name(for: PixelSize(width: 900, height: 900)), "1 : 1")
        XCTAssertEqual(CropAspect.name(for: PixelSize(width: 1001, height: 667)), "3 : 2")
        XCTAssertNil(CropAspect.name(for: PixelSize(width: 1000, height: 700)))
    }

    func testClampedIsWholePixelsInsideTheCanvas() {
        XCTAssertEqual(CropEditing.clamped(CGRect(x: -20.4, y: 10.6, width: 5000, height: 0.2), canvas: hd), CGRect(x: 0, y: 11, width: 1920, height: 1))
        XCTAssertEqual(CropEditing.clamped(CGRect(x: 1900, y: 1070, width: 100, height: 100), canvas: hd), CGRect(x: 1820, y: 980, width: 100, height: 100))
    }
}
