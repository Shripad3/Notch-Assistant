import AppKit

struct InstalledApp: Sendable, Equatable {
    let name: String
    let url: URL
}

enum InstalledApps {
    private static let directories = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Scanned per call: cheap at this size, and never stale after an install.
    static func scan() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        let fileManager = FileManager.default
        let paths = directories.flatMap { directory in
            ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { directory + "/" + $0 }
        } + ["/System/Library/CoreServices/Finder.app"]

        for path in paths {
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent
            guard seen.insert(name).inserted else { continue }
            apps.append(InstalledApp(name: name, url: url))
        }
        return apps
    }

    static func resolve(_ spoken: String) -> InstalledApp? {
        let apps = scan()
        guard let name = AppNameMatcher.match(spoken, candidates: apps.map(\.name), aliases: aliases()) else {
            return nil
        }
        return apps.first { $0.name == name }
    }

    static func defaultBrowser() -> InstalledApp? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            return nil
        }
        return InstalledApp(name: url.deletingPathExtension().lastPathComponent, url: url)
    }

    /// Built-in aliases plus user ones from the "appAliases" default
    /// (spoken → app name). The v1 settings UI edits the latter.
    private static func aliases() -> [String: String] {
        let custom = UserDefaults.standard.dictionary(forKey: "appAliases") as? [String: String] ?? [:]
        return AppNameMatcher.defaultAliases.merging(
            custom.map { (AppNameMatcher.key($0.key), $0.value) },
            uniquingKeysWith: { _, user in user }
        )
    }
}
