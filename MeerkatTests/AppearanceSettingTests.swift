import AppKit
import Testing
@testable import Meerkat

struct AppearanceSettingTests {
    @Test
    func labelsAndSchemes() {
        #expect(AppearanceSetting.system.title == "System")
        #expect(AppearanceSetting.light.title == "Light")
        #expect(AppearanceSetting.dark.title == "Dark")
        #expect(AppearanceSetting.system.colorScheme == nil)
        #expect(AppearanceSetting.light.colorScheme == .light)
        #expect(AppearanceSetting.dark.colorScheme == .dark)
        #expect(AppearanceSetting.system.nsAppearance == nil)
        #expect(AppearanceSetting.light.nsAppearance == NSAppearance(named: .aqua))
        #expect(AppearanceSetting.dark.nsAppearance == NSAppearance(named: .darkAqua))
    }

    @Test
    func readsStoredChoiceAndFallsBack() {
        #expect(AppearanceSetting.resolved(from: nil) == .system)
        #expect(AppearanceSetting.resolved(from: "dark") == .dark)
        #expect(AppearanceSetting.resolved(from: "light") == .light)
        #expect(AppearanceSetting.resolved(from: "not-a-theme") == .system)
    }
}

struct PanelTransparencyTests {
    @Test
    func clampsToUnitRange() {
        #expect(PanelTransparency.clamped(-0.4) == 0)
        #expect(PanelTransparency.clamped(0.35) == 0.35)
        #expect(PanelTransparency.clamped(1.8) == 1)
    }

    @Test
    func accessibilityFlagsForceOpaque() {
        #expect(
            PanelTransparency.effectiveValue(
                stored: 0.8,
                reduceTransparency: false,
                increaseContrast: false
            ) == 0.8
        )
        #expect(
            PanelTransparency.effectiveValue(
                stored: 0.8,
                reduceTransparency: true,
                increaseContrast: false
            ) == 0
        )
        #expect(
            PanelTransparency.effectiveValue(
                stored: 0.8,
                reduceTransparency: false,
                increaseContrast: true
            ) == 0
        )
    }

    @Test
    func pausedOnlyWhenSliderIsOnAndAccessibilityWins() {
        #expect(
            !PanelTransparency.isPaused(
                stored: 0,
                reduceTransparency: true,
                increaseContrast: false
            )
        )
        #expect(
            PanelTransparency.isPaused(
                stored: 0.4,
                reduceTransparency: true,
                increaseContrast: false
            )
        )
        #expect(
            !PanelTransparency.isPaused(
                stored: 0.4,
                reduceTransparency: false,
                increaseContrast: false
            )
        )
    }
}
