import AppKit
import FoundationModels

@Generable
struct OpenAppArguments: Sendable {
    @Guide(description: "The app's name as the user said it, e.g. \"Spotify\" or \"Arc\"")
    var appName: String
}

struct OpenAppTool: AssistantTool {
    let name = "openApp"
    let title = "Open app"
    let symbol = "app.badge"
    let keywords: Set<String> = ["open", "launch", "start", "app", "application", "browser"]
    let description = """
        Launch an installed Mac app by name. "open Spotify" → appName "Spotify". \
        "open my browser" → appName "my browser", exactly as said. \
        Not for websites: YouTube and Gmail are websites, use openURL.
        """
    let requiresNetwork = false
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    func target(of arguments: OpenAppArguments) -> String {
        arguments.appName
    }

    func execute(_ arguments: OpenAppArguments) async throws -> ToolResult {
        let app: InstalledApp?
        switch ground(arguments.appName) {
        case .defaultBrowser:
            app = InstalledApps.defaultBrowser()
        case .named(let name):
            app = InstalledApps.resolve(name)
        case .unspoken:
            // "open again" became openApp "Finder": the model filled in an app
            // the user never named. Refuse rather than open it.
            Log.tools.notice("openApp: \"\(arguments.appName, privacy: .public)\" was not spoken")
            throw ToolError("I didn't catch which app to open")
        }
        guard let app else {
            throw ToolError("I couldn't find an app called \"\(arguments.appName)\"")
        }
        try Task.checkCancellation()
        Log.tools.notice("openApp → \(app.url.path, privacy: .public)")
        _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        return "Opened \(app.name)"
    }

    func directArguments(for command: DirectCommand) -> OpenAppArguments? {
        guard ["open", "launch", "start"].contains(command.verb) else { return nil }
        let name = command.rest
        guard AppNameMatcher.isGenericBrowser(name) || InstalledApps.resolve(name) != nil else { return nil }
        return OpenAppArguments(appName: name)
    }

    private enum Grounded { case named(String), defaultBrowser, unspoken }

    /// The app must be one the user named: said outright, said through an
    /// alias ("vs code"), or "my browser" for the default browser.
    private func ground(_ appName: String) -> Grounded {
        guard let transcript = CommandContext.transcript else { return .named(appName) }
        if AppNameMatcher.isGenericBrowser(appName) || Grounding.mentionsGenericBrowser(in: transcript) {
            // The model turns "my browser" into "Safari"; trust what was said.
            if !Grounding.mentions(appName, in: transcript) { return .defaultBrowser }
        }
        if Grounding.mentions(appName, in: transcript) { return .named(appName) }
        if let alias = Grounding.spokenAlias(for: appName, in: transcript) { return .named(alias) }
        return .unspoken
    }
}
