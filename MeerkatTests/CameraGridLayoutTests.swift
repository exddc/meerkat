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

    @Test
    func growsForAdditionalRows() {
        #expect(CameraGridLayout.settingsPanelHeight == 605)
        #expect(CameraGridLayout.panelHeight(for: 2) == 475.5)
        #expect(CameraGridLayout.panelHeight(for: 4) == CameraGridLayout.panelMinimumHeight)
        #expect(CameraGridLayout.panelHeight(for: 5) == 360.25)
    }

    @Test
    func constrainsPanelHeightToTheDisplay() {
        #expect(CameraGridLayout.constrainedHeight(700, maximum: 500) == 500)
        #expect(CameraGridLayout.constrainedHeight(360.25, maximum: 500) == 360.25)
        #expect(CameraGridLayout.constrainedHeight(700, maximum: nil) == 700)
    }
}
