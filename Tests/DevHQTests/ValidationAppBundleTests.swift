import XCTest
@testable import DevHQ

final class ValidationAppBundleTests: XCTestCase {
    func testValidationMetadataRestoresOnlyIsolatedDirectories() throws {
        let environment = try XCTUnwrap(ValidationAppBundle.validationEnvironment(from: [
            "DevHQValidationHome": "/tmp/validation/home",
            "DevHQValidationConfigDirectory": "/tmp/validation/config",
            "DevHQValidationCacheDirectory": "/tmp/validation/cache",
            "DevHQValidationXDGConfigHome": "/tmp/validation/xdg-config",
            "DevHQValidationXDGCacheHome": "/tmp/validation/xdg-cache",
            "CFBundleName": "DevHQ Terminal Validation"
        ]))

        XCTAssertEqual(environment["DEVHQ_CONFIG_DIR"], "/tmp/validation/config")
        XCTAssertEqual(environment["DEVHQ_CACHE_DIR"], "/tmp/validation/cache")
        XCTAssertEqual(environment["HOME"], "/tmp/validation/home")
        XCTAssertNil(ValidationAppBundle.validationEnvironment(from: [:]))
    }

    func testValidationWorkspaceIsAddedOnlyWhenAbsent() {
        XCTAssertEqual(
            ValidationAppBundle.validationArguments(from: [], workspace: "/workspace"),
            ["--workspace", "/workspace"]
        )
        XCTAssertEqual(
            ValidationAppBundle.validationArguments(
                from: ["--workspace", "/other"], workspace: "/workspace"
            ),
            ["--workspace", "/other"]
        )
    }
}
