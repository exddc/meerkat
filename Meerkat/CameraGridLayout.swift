import Foundation

enum CameraGridLayout {
    static let panelWidth: CGFloat = 420
    static let panelMinimumHeight: CGFloat = 242
    static let settingsPanelHeight = panelMinimumHeight * 2
    static let spacing: CGFloat = 4
    static let padding: CGFloat = 4

    static func columnCount(for cameraCount: Int) -> Int {
        cameraCount <= 2 ? 1 : 2
    }

    static func panelHeight(for cameraCount: Int) -> CGFloat {
        guard cameraCount > 0 else { return panelMinimumHeight }

        let columns = columnCount(for: cameraCount)
        let rows = CGFloat((cameraCount + columns - 1) / columns)
        let tileWidth = (
            panelWidth - (padding * 2) - (spacing * CGFloat(columns - 1))
        ) / CGFloat(columns)
        let tileHeight = tileWidth * 9 / 16
        let gridHeight = (padding * 2) + (tileHeight * rows) + (spacing * (rows - 1))
        return max(panelMinimumHeight, gridHeight)
    }

    static func constrainedHeight(_ height: CGFloat, maximum: CGFloat?) -> CGFloat {
        guard let maximum else { return height }
        return min(height, maximum)
    }
}
