import Testing
@testable import Meerkat

struct AppInfoTests {
    @Test
    func menuBarIdentity() {
        #expect(AppInfo.name == "Meerkat")
        #expect(AppInfo.menuBarSymbol == "eye")
    }
}
