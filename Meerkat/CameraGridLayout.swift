import Foundation
import SwiftUI

enum CameraGridLayout {
    static let panelWidth: CGFloat = 420
    static let panelMinimumHeight: CGFloat = 242
    static let settingsPanelHeight = panelMinimumHeight * 2
    static let spacing: CGFloat = 4
    static let padding: CGFloat = 4

    static func panelWidth(for panelSize: MenuBarPanelSize) -> CGFloat {
        switch panelSize {
        case .small: 240
        case .medium: panelWidth
        case .large: panelWidth * 2
        }
    }

    static func columnCount(
        for cameraCount: Int,
        panelSize: MenuBarPanelSize = .medium
    ) -> Int {
        guard panelSize != .small else { return 1 }
        return cameraCount <= 2 ? 1 : 2
    }

    static func canExpandTiles(
        for cameraCount: Int,
        panelSize: MenuBarPanelSize = .medium
    ) -> Bool {
        columnCount(for: cameraCount, panelSize: panelSize) > 1
    }

    static func panelHeight(
        for cameraCount: Int,
        panelSize: MenuBarPanelSize = .medium
    ) -> CGFloat {
        if panelSize == .small {
            return smallPanelHeight
        }

        let minimumHeight = panelMinimumHeight * (panelSize == .large ? 2 : 1)
        guard cameraCount > 0 else { return minimumHeight }

        let columns = columnCount(for: cameraCount, panelSize: panelSize)
        let rows = CGFloat((cameraCount + columns - 1) / columns)
        let tileWidth = (
            panelWidth(for: panelSize) - (padding * 2) - (spacing * CGFloat(columns - 1))
        ) / CGFloat(columns)
        let tileHeight = tileWidth * 9 / 16
        let gridHeight = (padding * 2) + (tileHeight * rows) + (spacing * (rows - 1))
        return panelSize == .large ? max(minimumHeight, gridHeight) : gridHeight
    }

    static func constrainedHeight(_ height: CGFloat, maximum: CGFloat?) -> CGFloat {
        guard let maximum else { return height }
        return min(height, maximum)
    }

    private static var smallPanelHeight: CGFloat {
        let tileWidth = panelWidth(for: .small) - (padding * 2)
        return (padding * 2) + (tileWidth * 9 / 16 * 1.5) + spacing
    }
}

struct CameraTileIDKey: LayoutValueKey {
    static let defaultValue: UUID? = nil
}

struct CameraTileLayout: Layout {
    let expandedCameraID: UUID?
    let panelSize: MenuBarPanelSize
    let viewportSize: CGSize

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? viewportSize.width
        guard expandedCameraID == nil else {
            return CGSize(width: width, height: viewportSize.height)
        }

        return CGSize(
            width: width,
            height: max(
                viewportSize.height,
                gridHeight(width: width, count: subviews.count)
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let contentBounds = bounds.insetBy(
            dx: CameraGridLayout.padding,
            dy: CameraGridLayout.padding
        )

        if let expandedCameraID,
           let selected = subviews.first(where: {
               $0[CameraTileIDKey.self] == expandedCameraID
           }) {
            for subview in subviews where subview[CameraTileIDKey.self] != expandedCameraID {
                subview.place(at: contentBounds.origin, proposal: .zero)
            }
            selected.place(
                at: contentBounds.origin,
                proposal: ProposedViewSize(contentBounds.size)
            )
            return
        }

        let columns = CameraGridLayout.columnCount(
            for: subviews.count,
            panelSize: panelSize
        )
        let tileWidth = (
            contentBounds.width
                - (CameraGridLayout.spacing * CGFloat(columns - 1))
        ) / CGFloat(columns)
        let tileSize = CGSize(width: tileWidth, height: tileWidth * 9 / 16)

        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            let row = index / columns
            subview.place(
                at: CGPoint(
                    x: contentBounds.minX
                        + CGFloat(column) * (tileWidth + CameraGridLayout.spacing),
                    y: contentBounds.minY
                        + CGFloat(row) * (tileSize.height + CameraGridLayout.spacing)
                ),
                proposal: ProposedViewSize(tileSize)
            )
        }
    }

    private func gridHeight(width: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let columns = CameraGridLayout.columnCount(for: count, panelSize: panelSize)
        let rows = CGFloat((count + columns - 1) / columns)
        let tileWidth = (
            width
                - (CameraGridLayout.padding * 2)
                - (CameraGridLayout.spacing * CGFloat(columns - 1))
        ) / CGFloat(columns)
        return (CameraGridLayout.padding * 2)
            + (tileWidth * 9 / 16 * rows)
            + (CameraGridLayout.spacing * (rows - 1))
    }
}
