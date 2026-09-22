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
            return bundle.url(
                forResource: name,
                withExtension: `extension`,
                subdirectory: subdirectory
            )
        }
        guard !isAppBundle(mainBundleURL) else { return nil }
        return Bundle.module.url(forResource: name, withExtension: `extension`, subdirectory: subdirectory)
    }

    static func directoryURL(
        named name: String,
        packagedResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL
    ) -> URL? {
        if let bundle = packagedBundle(resourceURL: packagedResourceURL) {
            let url = bundle.resourceURL?.appendingPathComponent(name, isDirectory: true)
            var isDirectory = ObjCBool(false)
            if let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url
            }
            return nil
        }
        guard !isAppBundle(mainBundleURL) else { return nil }
        return Bundle.module.resourceURL?.appendingPathComponent(name, isDirectory: true)
    }

    static func packagedBundle(resourceURL: URL?) -> Bundle? {
        guard let resourceURL else { return nil }
        return Bundle(url: resourceURL.appendingPathComponent(bundleName, isDirectory: true))
    }

    private static func isAppBundle(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }
}
