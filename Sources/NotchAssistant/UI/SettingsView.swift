import AppKit
import NotchAssistantCore
import Speech
import SwiftUI

/// The panes, in sidebar order.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case activation, model, capabilities, files, spotify, permissions, display

    var id: Self { self }

    var title: String {
        switch self {
        case .activation: "Activation"
        case .model: "Model & Voice"
        case .capabilities: "Capabilities"
        case .files: "Files"
        case .spotify: "Spotify"
        case .permissions: "Permissions"
        case .display: "Display"
        }
    }

    var symbol: String {
        switch self {
        case .activation: "ear"
        case .model: "cpu"
        case .capabilities: "square.grid.2x2"
        case .files: "folder"
        case .spotify: "music.note"
        case .permissions: "lock.shield"
        case .display: "display"
        }
    }
}

/// A sidebar of panes, like System Settings. Tabs overflowed into a »
/// menu once there were more than five.
struct SettingsView: View {
    let status: StatusModel
    @State private var selection: SettingsPane = .activation

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .activation: ActivationPane(status: status)
        case .model: ModelPane()
        case .capabilities: CapabilitiesPane()
        case .files: FilesPane()
        case .spotify: SpotifyPane()
        case .permissions: PermissionsPane()
        case .display: DisplayPane()
        }
    }
}

// MARK: - Activation

private struct ActivationPane: View {
    let status: StatusModel
    @AppStorage("wake.enabled") private var wakeEnabled = false
    @AppStorage(WakeWordListener.thresholdKey) private var threshold = Double(WakeWordListener.defaultThreshold)
    @AppStorage(PowerProfileMonitor.autoSwitchKey) private var autoSwitch = true
    @AppStorage(WakeEngine.defaultsKey) private var engine = WakeEngine.speech.rawValue
    @AppStorage(SpeechWakeListener.localeKey) private var accent = ""
    @State private var models: [String] = []
    @State private var accents: [Locale] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Hold to talk", value: "⌥ Space")
            } footer: {
                Text("Always available, including on battery. Escape cancels.")
            }
            Section {
                Toggle("Listen for “Alfred”", isOn: $wakeEnabled)
                LabeledContent("Status", value: status.wakeStatus.description)
                Picker("Detect with", selection: $engine) {
                    ForEach(WakeEngine.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                if engine == WakeEngine.speech.rawValue {
                    Picker("Accent", selection: $accent) {
                        Text("Automatic").tag("")
                        ForEach(accents, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                        }
                    }
                }
                if engine == WakeEngine.model.rawValue {
                VStack(alignment: .leading) {
                    Slider(value: $threshold, in: 0.2...0.8, step: 0.05) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("More").font(.caption)
                    } maximumValueLabel: {
                        Text("Fewer false wakes").font(.caption)
                    }
                    Text("Detection threshold \(threshold, format: .number.precision(.fractionLength(2))). Wakes are also confirmed by speech recognition, so a lower threshold is safe to try.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                Toggle("Pause on battery, in Low Power Mode and when the Mac is hot", isOn: $autoSwitch)
            } header: {
                Text("Hands-free")
            } footer: {
                Text("While listening for “Alfred”, macOS shows the orange microphone dot. Nothing leaves this Mac.")
            }
            if engine == WakeEngine.model.rawValue {
            Section {
                LabeledContent("Loaded models", value: models.isEmpty ? "None" : models.joined(separator: ", "))
                Button("Show Custom Models Folder") {
                    let folder = WakeWordModels.customFolder
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
            } header: {
                Text("Wake-word models")
            } footer: {
                Text("The bundled model hears some voices saying “Alfred” on its own, but not greetings run into it. Models trained with the openWakeWord notebook go in this folder and run alongside it. Turn listening off and on to load them.")
            }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            models = WakeWordModels.locate()?.2.map { $0.deletingPathExtension().lastPathComponent } ?? []
        }
        .task {
            accents = await SpeechTranscriber.supportedLocales
                .filter { $0.language.languageCode?.identifier == "en" }
                .sorted { $0.identifier < $1.identifier }
        }
    }
}

// MARK: - Model

private struct ModelPane: View {
    @AppStorage(SpokenResponses.defaultsKey) private var spoken = SpokenResponses.errorsOnly.rawValue
    @AppStorage("audio.duckWhileListening") private var duck = true
    @AppStorage(VoiceOption.defaultsKey) private var voiceID = ""
    @State private var voices = VoiceOption.available()
    @State private var preview = Speaker()

    var body: some View {
        Form {
            Section {
                LabeledContent("Backend", value: "Apple Foundation Models, on this Mac")
            } footer: {
                Text("The MLX backend needs macOS 27.")
            }
            Section {
                Toggle("Lower other audio while listening", isOn: $duck)
            } footer: {
                Text("Turns the Mac's volume down while you hold the hotkey, so music doesn't drown out your command. It's restored as soon as you let go.")
            }
            Section {
                Picker("Voice", selection: $voiceID) {
                    Text("Automatic (best available)").tag("")
                    ForEach(voices) { voice in
                        Text("\(voice.name) — \(voice.accent) · \(voice.quality)").tag(voice.id)
                    }
                }
                HStack {
                    Button("Preview") { preview.say("Good evening. I've opened Spotify for you.") }
                    Button("Download Natural Voices…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")!)
                    }
                    Spacer()
                    Button("Refresh List") { voices = VoiceOption.available() }
                }
            } header: {
                Text("Voice")
            } footer: {
                if !voices.contains(where: { $0.quality != "Basic" }) {
                    Text("Only basic voices are installed, which is why it sounds robotic. In System Settings › Accessibility › Spoken Content › System Voice › Manage Voices, download a Premium or Enhanced voice (for example English (UK) › Jamie or Daniel), then click Refresh List.")
                }
            }
            Section {
                Picker("Speak responses", selection: $spoken) {
                    ForEach(SpokenResponses.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("Errors only speaks when something goes wrong. When the notch is hidden because there's no built-in display, results are spoken too.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Capabilities

/// Generated from registry metadata: adding a tool adds its toggle here
/// without touching this file (spec §9 "Adding a tool later").
private struct CapabilitiesPane: View {
    private let groups: [(title: String, tools: [AnyAssistantTool])] = {
        let tools = ToolRegistry.standard.tools.filter { $0.reversibility != .refused }
        return [
            ("Actions", tools.filter { $0.reversibility == .notApplicable }),
            ("File changes (undoable)", tools.filter { $0.reversibility == .reversible }),
        ].filter { !$0.1.isEmpty }
    }()

    @AppStorage(SearchEngine.defaultsKey) private var searchEngine = SearchEngine.google.rawValue
    @AppStorage("youtube.autoplay") private var youtubeAutoplay = true
    @AppStorage(WeatherSettings.cityKey) private var weatherCity = ""

    var body: some View {
        Form {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.tools, id: \.name) { ToolToggle(tool: $0) }
                }
            }
            Section {
                TextField("City", text: $weatherCity, prompt: Text(WeatherSettings.defaultCity))
            } header: {
                Text("Weather")
            } footer: {
                Text("Used when you don't name a place. Forecasts come from Apple Weather when the app is signed with a WeatherKit profile, otherwise from Open-Meteo (free, no account). Only the place is sent.")
            }
            WeatherAttributionRow()
            Section {
                Toggle("Play the first YouTube result automatically", isOn: $youtubeAutoplay)
            } header: {
                Text("YouTube")
            } footer: {
                Text("Uses Accessibility to press the top video on the results page, skipping Shorts and ads. If it can't, the results page stays open for you to choose.")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Do Not Disturb runs two shortcuts you create once in the Shortcuts app:")
                    Text("1. A shortcut named **DND On** with one action: *Set Focus* → Do Not Disturb → **On** (until turned off).")
                    Text("2. A second one named **DND Off** with *Set Focus* → Do Not Disturb → **Off**.")
                    Text("Any names work if they contain “DND” or “Do Not Disturb” plus “On” or “Off”. The first use asks to let Notch Assistant control Shortcuts.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Button("Open Shortcuts") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                }
            } header: {
                Text("Do Not Disturb")
            }
            Section {
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("A capability that is off is removed from the model entirely, so it can't be called — it isn't just hidden.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolToggle: View {
    let tool: AnyAssistantTool
    @AppStorage private var isEnabled: Bool

    init(tool: AnyAssistantTool) {
        self.tool = tool
        _isEnabled = AppStorage(wrappedValue: true, ToolRegistry.enabledKey(for: tool.name))
    }

    var body: some View {
        Toggle(isOn: $isEnabled) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.label.title)
                    Text(requirements).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: tool.label.symbol)
            }
        }
    }

    private var requirements: String {
        var parts = [tool.requiresNetwork ? "Needs internet" : "Works offline"]
        switch tool.permission {
        case .none: break
        case .files: parts.append("Needs Files and Folders")
        case .automation: parts.append("Needs Automation")
        case .accessibility: parts.append("Needs Accessibility")
        case .varies: parts.append("May need permissions")
        }
        return parts.joined(separator: " · ")
    }
}

/// Apple Weather's required attribution, shown when WeatherKit is in use.
private struct WeatherAttributionRow: View {
    @State private var attribution: (mark: URL, legal: URL)?

    var body: some View {
        Group {
            if let attribution {
                HStack {
                    AsyncImage(url: attribution.mark) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text("Apple Weather")
                    }
                    .frame(height: 14)
                    Spacer()
                    Link("Other data sources", destination: attribution.legal).font(.caption)
                }
            }
        }
        .task { attribution = await AppleWeather.attribution() }
    }
}

// MARK: - Files

/// Spec §10's Files pane: where file tools may act, the limits, what the
/// agent can never do (stated, not a toggle), and the undo history.
private struct FilesPane: View {
    @State private var history: [FileJournal.Entry] = []
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("Notch Assistant can't read what's inside your files, can't edit them, and can't delete anything permanently. “Delete” moves to the Trash, and it never empties the Trash.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Where it can act") {
                ForEach(["Documents", "Downloads", "Desktop"], id: \.self) { name in
                    Label(name, systemImage: "folder")
                }
                Text("Hidden files, apps and Library folders are never touched. One file changes at once; 2–20 files ask for a confirmation; more than 20 are refused. Existing files are never overwritten; a number is added to the new name instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if history.isEmpty {
                    Text("No changes yet").foregroundStyle(.secondary)
                }
                ForEach(history.prefix(30)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary)
                                .strikethrough(entry.status == .undone)
                            Text(entry.date, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.status == .undone {
                            Text("Undone").font(.caption).foregroundStyle(.secondary)
                        } else if !entry.steps.isEmpty {
                            Button("Undo") { undo(entry) }.controlSize(.small)
                        }
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Recent changes")
            } footer: {
                Text("Say “Alfred, undo that” to reverse the latest one.")
            }
        }
        .formStyle(.grouped)
        .onAppear { history = FileChanges.history }
    }

    private func undo(_ entry: FileJournal.Entry) {
        do {
            message = try FileChanges.undo(entry.id)
        } catch {
            message = AssistantFailure(error).message
        }
        history = FileChanges.history
    }
}

// MARK: - Spotify

private struct SpotifyPane: View {
    @AppStorage(SpotifyWebAPI.clientIDKey) private var clientID = ""
    @State private var isSignedIn = SpotifyWebAPI.isSignedIn
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("Play and pause work without this. Connecting lets \"play <song>\" and \"play my <name> playlist\" start the exact track or playlist, instead of opening Spotify's search.")
                    .foregroundStyle(.secondary)
            }
            Section("1. Create a Spotify app") {
                Link("Open the Spotify developer dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                LabeledContent("Redirect URI") {
                    HStack {
                        Text(SpotifyWebAPI.registeredRedirectURI).textSelection(.enabled).monospaced()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyWebAPI.registeredRedirectURI, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                Text("Tick \"Web API\" when asked which APIs you'll use.").font(.caption).foregroundStyle(.secondary)
            }
            Section("2. Paste its Client ID") {
                TextField("Client ID", text: $clientID).monospaced()
            }
            Section("3. Connect") {
                HStack {
                    Text(isSignedIn ? "Connected" : "Not connected")
                        .foregroundStyle(isSignedIn ? .green : .secondary)
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    if isSignedIn {
                        Button("Disconnect") {
                            Task {
                                await SpotifyWebAPI.shared.signOut()
                                isSignedIn = SpotifyWebAPI.isSignedIn
                            }
                        }
                    } else {
                        Button("Sign in with Spotify…", action: signIn)
                            .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func signIn() {
        isWorking = true
        message = "Finish signing in in your browser."
        Task {
            do {
                try await SpotifyWebAPI.shared.signIn()
                message = nil
            } catch {
                message = AssistantFailure(error).message
            }
            isSignedIn = SpotifyWebAPI.isSignedIn
            isWorking = false
            NSApp.activate()
        }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @State private var items: [PermissionItem] = []
    @State private var modelProblem = PermissionChecker.appleIntelligenceProblem()

    var body: some View {
        Form {
            Section("On-device model") {
                row(
                    title: "Apple Intelligence",
                    detail: "Understands your commands, on this Mac",
                    status: modelProblem.map { ($0, Color.orange) } ?? ("Ready", .green),
                    link: .appleIntelligence
                )
            }
            Section("Privacy") {
                ForEach(items) { item in
                    row(title: item.title, detail: item.neededFor, status: Self.describe(item.status), link: item.link)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Grants can change in System Settings while this pane is open.
            while !Task.isCancelled {
                items = await PermissionChecker.all()
                modelProblem = PermissionChecker.appleIntelligenceProblem()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row(title: String, detail: String, status: (String, Color), link: SystemSettingsPane) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status.0).font(.caption).foregroundStyle(status.1)
            Button("Open…") { NSWorkspace.shared.open(link.url) }
                .controlSize(.small)
        }
    }

    private static func describe(_ status: PermissionStatus) -> (String, Color) {
        switch status {
        case .granted: ("Granted", .green)
        case .denied: ("Denied", .red)
        case .notRequested: ("Not requested", .secondary)
        case .askedOnFirstUse: ("Asked on first use", .secondary)
        case .unknown: ("Unknown", .secondary)
        }
    }
}

// MARK: - Display

private struct DisplayPane: View {
    @AppStorage(DisplayFallback.defaultsKey) private var fallback = DisplayFallback.hide.rawValue

    var body: some View {
        Form {
            Section {
                Picker("When there's no notched display", selection: $fallback) {
                    ForEach(DisplayFallback.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("The notch only ever appears on the MacBook's built-in display. This applies when that display is unavailable — lid closed, display asleep, or Sidecar. The hotkey keeps working under Hide; the menu bar icon still shows what's happening.")
            }
        }
        .formStyle(.grouped)
    }
}
