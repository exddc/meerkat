import XCTest
@testable import Meerkat

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testEnablingRegistersService() async {
        let service = LaunchAtLoginServiceStub(status: .disabled)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        await waitForUpdate(toFinishIn: controller)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
    }

    func testDisablingUnregistersService() async {
        let service = LaunchAtLoginServiceStub(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)
        await waitForUpdate(toFinishIn: controller)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testFailureRestoresServiceState() async {
        let service = LaunchAtLoginServiceStub(status: .disabled)
        service.registerError = TestError.registrationFailed
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        await waitForUpdate(toFinishIn: controller)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }

    private func waitForUpdate(toFinishIn controller: LaunchAtLoginController) async {
        while controller.isUpdating {
            await Task.yield()
        }
    }
}

@MainActor
private final class LaunchAtLoginServiceStub: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

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
}

private enum TestError: Error {
    case registrationFailed
}
