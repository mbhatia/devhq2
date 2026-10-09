import Foundation

/// Locates DevHQ's SwiftPM resources in both an installed app and development builds.
enum DevHQResourceBundle {
    private static let bundleName = "DevHQ_DevHQ.bundle"

    static func url(
        forResource name: String,
        withExtension extension: String,
        subdirectory: String,
        packagedResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL
    ) -> URL? {
        if let bundle = packagedBundle(resourceURL: packagedResourceURL) {
            return url(
                in: bundle,
                forResource: name,
                withExtension: `extension`,
                subdirectory: subdirectory
            )
        }
        guard !isAppBundle(mainBundleURL) else { return nil }
        return url(in: Bundle.module, forResource: name, withExtension: `extension`, subdirectory: subdirectory)
    }

    /// `.copy("Resources")` is nested inside Contents/Resources with SwiftPM's
    /// Xcode build system, but is itself the resource root in a flat bundle.
    static func url(in bundle: Bundle, forResource name: String, withExtension extension: String, subdirectory: String) -> URL? {
        bundle.url(forResource: name, withExtension: `extension`, subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: `extension`, subdirectory: "Resources/\(subdirectory)")
    }

    static func directoryURL(
        named name: String,
        packagedResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL
    ) -> URL? {
        if let bundle = packagedBundle(resourceURL: packagedResourceURL) {
            return directoryURL(in: bundle, named: name)
        }
        guard !isAppBundle(mainBundleURL) else { return nil }
        return directoryURL(in: Bundle.module, named: name)
    }

    private static func directoryURL(in bundle: Bundle, named name: String) -> URL? {
        guard let root = bundle.resourceURL else { return nil }
        for subdirectory in [name, "Resources/\(name)"] {
            let url = root.appendingPathComponent(subdirectory, isDirectory: true)
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    static func packagedBundle(resourceURL: URL?) -> Bundle? {
        guard let resourceURL else { return nil }
        return Bundle(url: resourceURL.appendingPathComponent(bundleName, isDirectory: true))
    }

    private static func isAppBundle(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }
}
