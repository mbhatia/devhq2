import Darwin
import Foundation

/// Creates a separately identified app bundle only when the validation launcher requests it.
enum ValidationAppBundle {
    private static let bundleIdentifier = "com.github.mbhatia.devhq.terminal-validation"

    static func reexecIfRequested() {
        if Bundle.main.bundleIdentifier == bundleIdentifier {
            restoreBundledEnvironment()
            if !CommandLine.arguments.contains("--workspace") {
                do {
                    reexec(
                        at: try executableURL(),
                        adding: validationArguments(
                            from: [],
                            workspace: requiredBundledValue(for: "DevHQValidationWorkspace")
                        )
                    )
                } catch {
                    fputs("Could not restore the DevHQ validation app: \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }

        let environment = ProcessInfo.processInfo.environment
        guard let bundlePath = environment["DEVHQ_VALIDATION_BUNDLE_PATH"],
              !bundlePath.isEmpty,
              environment["DEVHQ_VALIDATION_BUNDLED"] != "1" else {
            return
        }

        do {
            let bundleURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
            let executableURL = try executableURL()
            let bundledExecutableURL = try stage(
                executable: executableURL,
                at: bundleURL
            )
            setenv("DEVHQ_VALIDATION_BUNDLED", "1", 1)
            reexec(at: bundledExecutableURL)
        } catch {
            fputs("Could not stage the DevHQ validation app: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func executableURL() throws -> URL {
        var bufferSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &bufferSize)
        var buffer = [CChar](repeating: 0, count: Int(bufferSize))
        guard _NSGetExecutablePath(&buffer, &bufferSize) == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private static func restoreBundledEnvironment() {
        let info = Bundle.main.infoDictionary?.compactMapValues { $0 as? String } ?? [:]
        guard let environment = validationEnvironment(from: info) else {
            fputs("DevHQ validation app is missing isolation metadata.\n", stderr)
            exit(EXIT_FAILURE)
        }
        for (key, value) in environment {
            setenv(key, value, 1)
        }
    }

    static func validationEnvironment(from info: [String: String]) -> [String: String]? {
        let keys = [
            ("HOME", "DevHQValidationHome"),
            ("DEVHQ_CONFIG_DIR", "DevHQValidationConfigDirectory"),
            ("DEVHQ_CACHE_DIR", "DevHQValidationCacheDirectory"),
            ("XDG_CONFIG_HOME", "DevHQValidationXDGConfigHome"),
            ("XDG_CACHE_HOME", "DevHQValidationXDGCacheHome"),
            ("DEVHQ_APP_NAME", "CFBundleName")
        ]
        var environment: [String: String] = [:]
        for (environmentKey, infoKey) in keys {
            guard let value = info[infoKey], !value.isEmpty else { return nil }
            environment[environmentKey] = value
        }
        return environment
    }

    static func validationArguments(from arguments: [String], workspace: String) -> [String] {
        arguments.contains("--workspace") ? arguments : arguments + ["--workspace", workspace]
    }

    private static func requiredBundledValue(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            fputs("DevHQ validation app is missing \(key).\n", stderr)
            exit(EXIT_FAILURE)
        }
        return value
    }

    private static func stage(executable: URL, at bundleURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let bundledExecutableURL = macOSURL.appendingPathComponent("DevHQ Terminal Validation")

        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: executable, to: bundledExecutableURL)

        let siblingDirectory = executable.deletingLastPathComponent()
        for item in try fileManager.contentsOfDirectory(
            at: siblingDirectory,
            includingPropertiesForKeys: nil
        ) where item.pathExtension == "bundle" {
            try fileManager.copyItem(
                at: item,
                to: resourcesURL.appendingPathComponent(item.lastPathComponent)
            )
        }

        let environment = ProcessInfo.processInfo.environment
        let info: [String: String] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": bundledExecutableURL.lastPathComponent,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "DevHQ Terminal Validation",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "DevHQValidationHome": environment["HOME"] ?? "",
            "DevHQValidationConfigDirectory": environment["DEVHQ_CONFIG_DIR"] ?? "",
            "DevHQValidationCacheDirectory": environment["DEVHQ_CACHE_DIR"] ?? "",
            "DevHQValidationXDGConfigHome": environment["XDG_CONFIG_HOME"] ?? "",
            "DevHQValidationXDGCacheHome": environment["XDG_CACHE_HOME"] ?? "",
            "DevHQValidationWorkspace": environment["DEVHQ_VALIDATION_WORKSPACE"] ?? ""
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        return bundledExecutableURL
    }

    private static func reexec(at executable: URL, adding extraArguments: [String] = []) -> Never {
        let arguments = [executable.path] + Array(CommandLine.arguments.dropFirst()) + extraArguments
        let argv = arguments.map { strdup($0) } + [nil]
        execv(executable.path, argv)
        perror("execv")
        exit(EXIT_FAILURE)
    }
}
