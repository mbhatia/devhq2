import Foundation

/// Headless packaged-app resource validation for release assembly checks.
enum BundledResourcesCLI {
    static func isVerificationInvocation(_ arguments: [String]) -> Bool {
        arguments.count == 2 && arguments[1] == "--verify-bundled-resources"
    }

    @discardableResult
    static func run(
        packagedResourceURL: URL? = Bundle.main.resourceURL,
        output: (String) -> Void = { print($0) },
        errorOutput: (String) -> Void = {
            FileHandle.standardError.write(Data(($0 + "\n").utf8))
        }
    ) -> Int32 {
        guard let resourceBundle = DevHQResourceBundle.packagedBundle(resourceURL: packagedResourceURL),
              let fontURLs = TerminalFont.verifiedBundledFontURLs(in: resourceBundle) else {
            errorOutput("devhq: bundled terminal fonts could not be resolved from the app resources")
            return 1
        }

        let resourcePath = resourceBundle.bundleURL.standardizedFileURL.path + "/"
        guard fontURLs.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(resourcePath) }) else {
            errorOutput("devhq: bundled terminal fonts were not resolved from the app resources")
            return 1
        }
        fontURLs.forEach { output($0.path) }
        return 0
    }
}
