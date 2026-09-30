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
}
