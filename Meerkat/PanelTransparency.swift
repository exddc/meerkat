import Foundation
import SwiftUI

/// How much of the panel's opaque tray yields to behind-window vibrancy.
///
/// OpenUsage keeps this as a discrete on/off so tests stay tractable. TW-374 asks
/// for a slider, so the stored value is continuous (`0` solid … `1` glass) while
/// the rest of the rules stay the same: the desktop shows through vibrancy rather
/// than window alpha (fading the window would dim the text), and macOS Reduce
/// Transparency / Increase Contrast clamp everything back to opaque.
enum PanelTransparency {
    static let key = "panelTransparency"
    static let fallback = 0.0
    static let range: ClosedRange<Double> = 0...1

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Accessibility needs win over the slider. Either flag forces a solid panel.
    static func effectiveValue(
        stored: Double,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Double {
        if reduceTransparency || increaseContrast {
            return fallback
        }
        return clamped(stored)
    }

    /// True when the user asked for glass but a system accessibility setting is
    /// holding the panel solid, so Settings can explain why the slider is paused.
    static func isPaused(
        stored: Double,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        clamped(stored) > fallback && (reduceTransparency || increaseContrast)
    }
}

private struct PanelTransparencyKey: EnvironmentKey {
    static let defaultValue = PanelTransparency.fallback
}

extension EnvironmentValues {
    var panelTransparency: Double {
        get { self[PanelTransparencyKey.self] }
        set { self[PanelTransparencyKey.self] = newValue }
    }
}
