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

    @Test(arguments: [0, 1, 2, 3, 10])
    func smallLayoutUsesOneColumn(cameraCount: Int) {
        #expect(
            CameraGridLayout.columnCount(for: cameraCount, panelSize: .small) == 1
        )
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
        #expect(CameraGridLayout.settingsPanelHeight == 484)
        #expect(CameraGridLayout.panelHeight(for: 2) == 475.5)
        #expect(CameraGridLayout.panelHeight(for: 4) == 241.5)
        #expect(CameraGridLayout.panelHeight(for: 5) == 360.25)
    }

    @Test
    func usesRequestedPanelSize() {
        #expect(CameraGridLayout.panelWidth(for: .small) == 240)
        #expect(CameraGridLayout.panelWidth(for: .medium) == 420)
        #expect(CameraGridLayout.panelWidth(for: .large) == 840)
        #expect(CameraGridLayout.panelHeight(for: 4, panelSize: .small) == 207.75)
        #expect(CameraGridLayout.panelHeight(for: 4, panelSize: .medium) == 241.5)
        #expect(CameraGridLayout.panelHeight(for: 4, panelSize: .large) == 484)
    }

    @Test
    func constrainsPanelHeightToTheDisplay() {
        #expect(CameraGridLayout.constrainedHeight(700, maximum: 500) == 500)
        #expect(CameraGridLayout.constrainedHeight(360.25, maximum: 500) == 360.25)
        #expect(CameraGridLayout.constrainedHeight(700, maximum: nil) == 700)
    }
}
