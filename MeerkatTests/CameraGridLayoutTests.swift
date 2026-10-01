import Foundation
import Testing
@testable import Meerkat

struct CameraGridLayoutTests {
    @Test(arguments: [
        (0, 1),
        (1, 1),
        (2, 1),
        (3, 2),
        (4, 2),
        (5, 2),
        (10, 2),
    ])
    func usesAtMostTwoColumns(cameraCount: Int, expectedColumns: Int) {
        #expect(CameraGridLayout.columnCount(for: cameraCount) == expectedColumns)
    }

    @Test(arguments: [0, 1, 2])
    func doesNotExpandFullWidthTiles(cameraCount: Int) {
        #expect(!CameraGridLayout.canExpandTiles(for: cameraCount))
    }

    @Test(arguments: [3, 4, 5, 10])
    func expandsTilesInMultiColumnGrids(cameraCount: Int) {
        #expect(CameraGridLayout.canExpandTiles(for: cameraCount))
    }

    @Test(arguments: [
        (0, 239.75),
        (1, 239.75),
        (2, 475.5),
        (3, 241.5),
        (4, 241.5),
        (5, 360.25),
        (8, 479),
        (9, 484),
        (10, 484),
    ])
    func panelFitsCameraRows(cameraCount: Int, expectedHeight: CGFloat) {
        #expect(CameraGridLayout.panelHeight(for: cameraCount) == expectedHeight)
    }

    @Test(arguments: [3, 4, 5, 10])
    func expandedPanelFitsOneFullWidthCamera(cameraCount: Int) {
        #expect(CameraGridLayout.panelHeight(for: cameraCount, isExpanded: true) == 239.75)
    }

    @Test(arguments: [420.0, 320.0])
    func gridHeightIncludesOnlyTilesSpacingAndPadding(width: CGFloat) {
        let tileWidth = (width - 12) / 2
        #expect(CameraGridLayout.gridHeight(width: width, cameraCount: 3) == tileWidth * 9 / 16 * 2 + 12)
        #expect(CameraGridLayout.gridHeight(width: width, cameraCount: 0) == 0)
    }

    @Test
    func largeGridExceedsViewportAndCanScroll() {
        #expect(CameraGridLayout.gridHeight(width: 420, cameraCount: 10) > CameraGridLayout.panelHeight(for: 10))
    }
}
