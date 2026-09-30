import Foundation
import SwiftUI

enum CameraGridLayout {
    static let panelWidth: CGFloat = 420
    static let settingsHeight: CGFloat = 484
    static let spacing: CGFloat = 4
    static let padding: CGFloat = 4

    static func columnCount(for cameraCount: Int) -> Int {
        cameraCount <= 2 ? 1 : 2
    }

    static func canExpandTiles(for cameraCount: Int) -> Bool {
        columnCount(for: cameraCount) > 1
    }

    static func gridHeight(width: CGFloat, cameraCount: Int) -> CGFloat {
        guard cameraCount > 0 else { return 0 }
        let columns = columnCount(for: cameraCount)
        let rows = CGFloat((cameraCount + columns - 1) / columns)
        let tileWidth = (
            width - padding * 2 - spacing * CGFloat(columns - 1)
        ) / CGFloat(columns)
        return padding * 2
            + tileWidth * 9 / 16 * rows
            + spacing * (rows - 1)
    }

    static func panelHeight(for cameraCount: Int, isExpanded: Bool = false) -> CGFloat {
        min(
            settingsHeight,
            gridHeight(
                width: panelWidth,
                cameraCount: isExpanded ? 1 : max(1, cameraCount)
            )
        )
    }
}

struct CameraTileIDKey: LayoutValueKey {
    static let defaultValue: UUID? = nil
}

struct CameraTileLayout: Layout {
    let expandedCameraID: UUID?
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
                CameraGridLayout.gridHeight(width: width, cameraCount: subviews.count)
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

        let columns = CameraGridLayout.columnCount(for: subviews.count)
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
}
