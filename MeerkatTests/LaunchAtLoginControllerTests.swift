import Testing
@testable import Meerkat

@MainActor
struct LaunchAtLoginControllerTests {
    @Test
    func testEnablingRegistersService() async {
        let service = LaunchAtLoginServiceStub(status: .disabled)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        await waitForUpdate(toFinishIn: controller)

        #expect(service.registerCallCount == 1)
        #expect(controller.isEnabled)
    }

    @Test
    func testDisablingUnregistersService() async {
        let service = LaunchAtLoginServiceStub(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)
        await waitForUpdate(toFinishIn: controller)

        #expect(service.unregisterCallCount == 1)
        #expect(!controller.isEnabled)
    }

    @Test
    func testFailureRestoresServiceState() async {
        let service = LaunchAtLoginServiceStub(status: .disabled)
        service.registerError = TestError.registrationFailed
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        await waitForUpdate(toFinishIn: controller)

        #expect(!controller.isEnabled)
        #expect(controller.errorMessage != nil)
    }

    @Test
    func testPendingApprovalCanOpenSystemSettings() {
        let service = LaunchAtLoginServiceStub(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        controller.openSystemSettings()

        #expect(controller.isEnabled)
        #expect(controller.requiresApproval)
        #expect(service.openSystemSettingsCallCount == 1)
    }

    private func waitForUpdate(
        toFinishIn controller: LaunchAtLoginController,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if !controller.isUpdating { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isUpdating, "Login item update did not finish before \(timeout)")
    }
}

@MainActor
private final class LaunchAtLoginServiceStub: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() async throws {
        unregisterCallCount += 1
        status = .disabled
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}

private enum TestError: Error {
    case registrationFailed
}
