import AppKit
import NotchAssistantCore
import Speech
import ServiceManagement
import SwiftUI

/// The panes, in sidebar order.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case activation, model, conversation, capabilities, routines, clock, calendar, messages, recording, files, spotify, permissions, display

    var id: Self { self }

    var title: String {
        switch self {
        case .activation: "Activation"
        case .model: "Model & Voice"
        case .conversation: "Conversation"
        case .capabilities: "Capabilities"
        case .routines: "Routines"
        case .clock: "Clock"
        case .calendar: "Calendar"
        case .messages: "Messages & Email"
        case .recording: "Recording"
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
        case .conversation: "bubble.left.and.bubble.right"
        case .capabilities: "square.grid.2x2"
        case .routines: "list.bullet.rectangle"
        case .clock: "alarm"
        case .calendar: "calendar"
        case .messages: "message"
        case .recording: "record.circle"
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
        case .conversation: ConversationPane()
        case .capabilities: CapabilitiesPane()
        case .routines: RoutinesPane()
        case .clock: ClockPane(status: status)
        case .calendar: CalendarPane()
        case .messages: MessagesPane()
        case .recording: RecordingPane()
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
    @AppStorage(AppDelegate.gesturesKey) private var gesturesEnabled = false
    @State private var openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
    @State private var loginNeedsApproval = LoginItem.needsApproval

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in
                        LoginItem.set(enabled)
                        loginNeedsApproval = LoginItem.needsApproval
                    }
                if loginNeedsApproval {
                    HStack {
                        Text("Allow Notch Assistant in Login Items to finish.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text("Timers and alarms only ring while Notch Assistant is running.")
            }
            Section {
                Toggle("Hand gestures", isOn: $gesturesEnabled)
                if gesturesEnabled {
                    LabeledContent("Status", value: status.gestureStatus)
                }
            } header: {
                Text("Gestures")
            } footer: {
                Text("Hold an open palm towards the camera for half a second to start listening, like saying “Alfred”. Make a fist to cancel, like Escape. Uses the camera continuously, so its green light stays on and it costs more energy than the wake word; it pauses on battery and when the Mac is hot. Nothing is recorded or stored.")
            }
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
    private let kokoro = KokoroVoice.shared

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
                    Section("Natural voices (Kokoro)") {
                        ForEach(KokoroVoice.voices, id: \.id) { voice in
                            Text(voice.name).tag(Speaker.neuralPrefix + voice.id)
                        }
                    }
                    Section("System voices") {
                        ForEach(voices) { voice in
                            Text("\(voice.name) — \(voice.accent) · \(voice.quality)").tag(voice.id)
                        }
                    }
                }
                .onChange(of: voiceID) { _, id in
                    // Picking a natural voice downloads the model the first time.
                    if id.hasPrefix(Speaker.neuralPrefix), kokoro.state != .ready {
                        Task { await kokoro.download() }
                    }
                }
                if voiceID.hasPrefix(Speaker.neuralPrefix) || kokoro.state != .notDownloaded {
                    kokoroStatus
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
                if voiceID.hasPrefix(Speaker.neuralPrefix) {
                    Text("Kokoro is an open-source neural voice (Apache-2.0) that runs on this Mac's Neural Engine. It's downloaded once (about 80 MB), then works offline. Until it's ready, the system voice speaks instead.")
                } else
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

    @ViewBuilder private var kokoroStatus: some View {
        HStack {
            switch kokoro.state {
            case .notDownloaded:
                Text("Natural voice not downloaded").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Download (80 MB)") { Task { await kokoro.download() } }
            case .downloading:
                ProgressView().controlSize(.small)
                Text("Downloading the natural voice…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            case .ready:
                Text("Natural voice ready, works offline").font(.caption).foregroundStyle(.green)
                Spacer()
                Button("Remove Download") { Task { await kokoro.remove() } }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                Button("Try Again") { Task { await kokoro.download() } }
            }
        }
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
        case .reminders: parts.append("Needs Reminders")
        case .calendar: parts.append("Needs your calendar")
        case .contacts: parts.append("Needs Contacts")
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

private struct ClockPane: View {
    let status: StatusModel
    @AppStorage(AlarmSounds.key(for: .alarm)) private var alarmSound = AlarmSounds.defaultSound(for: .alarm)
    @AppStorage(AlarmSounds.key(for: .timer)) private var timerSound = AlarmSounds.defaultSound(for: .timer)
    @AppStorage(StatusModel.notchCountdownKey) private var notchCountdown = true
    @State private var editing: AlarmDraft?

    var body: some View {
        Form {
            Section {
                let alarms = status.clock.alarms.sorted { Self.timeOfDay($0.fireDate) < Self.timeOfDay($1.fireDate) }
                if alarms.isEmpty {
                    Text("No alarms. Add one here or say “Alfred, wake me up at 7 on weekdays”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(alarms) { alarm in
                    AlarmRow(alarm: alarm) { editing = AlarmDraft(alarm) }
                }
                Button("Add Alarm…") { editing = AlarmDraft() }
            } header: {
                Text("Alarms")
            } footer: {
                Text("Switched-off alarms are kept but never ring. Alarms ring while Notch Assistant is running; if it isn't, a notification appears instead.")
            }
            Section {
                soundPicker("Alarm sound", selection: $alarmSound, kind: .alarm)
                soundPicker("Timer sound", selection: $timerSound, kind: .timer)
            } footer: {
                Text("“Test” rings the notch exactly as a real one would: sound, voice and the Stop button.")
            }
            Section {
                Toggle("Show running timers beside the notch", isOn: $notchCountdown)
            } footer: {
                Text("A small countdown sits next to the notch while a timer or the stopwatch runs. Hover over it to see every timer. The menu bar always shows it.")
            }
            Section("What you can say") {
                Text("“Set a timer for 10 minutes” · “Set a pasta timer for an hour and a half” · “How long is left?”")
                Text("“Wake me up at 7 on weekdays” · “Set an alarm for 6:30 tomorrow” · “What alarms do I have?”")
                Text("“Start the stopwatch” · “Lap” · “Remind me to call Mum at 6” · “What time is it in Tokyo?”")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            AlarmEditor(draft: draft) { editing = nil }
        }
    }

    private static func timeOfDay(_ date: Date) -> Int {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
    }

    private func soundPicker(_ title: String, selection: Binding<String>, kind: Countdown.Kind) -> some View {
        HStack {
            Picker(title, selection: selection) {
                ForEach(AlarmSounds.all, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: selection.wrappedValue) { _, name in NSSound(named: name)?.play() }
            Button("Test") { status.onTestAlert?(kind) }
        }
    }
}

/// One alarm in Settings: time, name and days, an on/off switch, edit and delete.
private struct AlarmRow: View {
    let alarm: Countdown
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.fireDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 22, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(alarm.isEnabled ? .primary : .secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit", action: edit)
            Button {
                ClockStore.shared.remove([alarm.id])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete alarm")
            Toggle("", isOn: Binding(get: { alarm.isEnabled }, set: { ClockStore.shared.setEnabled(alarm.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private var detail: String {
        let when = alarm.repeatDays.map { AlarmRepeat.describe($0).prefix(1).uppercased() + AlarmRepeat.describe($0).dropFirst() }
            ?? "Once, " + ClockFormat.when(alarm.fireDate, hasTime: false)
        return [alarm.label, when].compactMap { $0 }.joined(separator: " · ")
    }
}

/// An alarm being added or edited.
private struct AlarmDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var time: Date
    var label: String
    var days: Set<Int>

    init() {
        id = UUID()
        isNew = true
        time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
        label = ""
        days = []
    }

    init(_ alarm: Countdown) {
        id = alarm.id
        isNew = false
        time = alarm.fireDate
        label = alarm.label ?? ""
        days = alarm.repeatDays ?? []
    }
}

private struct AlarmEditor: View {
    @State var draft: AlarmDraft
    let done: () -> Void

    /// Monday first; 1 = Sunday … 7 = Saturday.
    private let order = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                TextField("Name", text: $draft.label, prompt: Text("Optional, e.g. Gym"))
                LabeledContent("Repeat") {
                    HStack(spacing: 4) {
                        ForEach(order, id: \.self) { day in
                            let on = draft.days.contains(day)
                            Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                                if on { draft.days.remove(day) } else { draft.days.insert(day) }
                            }
                            .buttonStyle(.bordered)
                            .tint(on ? .accentColor : nil)
                            .fontWeight(on ? .bold : .regular)
                            .help(Calendar.current.weekdaySymbols[day - 1])
                        }
                    }
                }
                Text(draft.days.isEmpty ? "Rings once, the next time it's this time." : "Rings " + AlarmRepeat.describe(draft.days) + ".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !draft.isNew {
                    Button("Delete", role: .destructive) {
                        ClockStore.shared.remove([draft.id])
                        done()
                    }
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 300)
    }

    private func save() {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: draft.time)
        let label = draft.label.trimmingCharacters(in: .whitespaces)
        if draft.isNew {
            ClockStore.shared.addAlarm(hour: clock.hour ?? 7, minute: clock.minute ?? 0, label: label, days: draft.days)
        } else {
            ClockStore.shared.updateAlarm(draft.id, hour: clock.hour ?? 7, minute: clock.minute ?? 0, label: label, days: draft.days)
        }
        done()
    }
}

private struct RecordingPane: View {
    @AppStorage(CaptureSettings.saveAudioKey) private var saveAudio = false
    @AppStorage(CaptureSettings.includeOthersKey) private var includeOthers = false
    @AppStorage(AppDelegate.pauseDuringCallsKey) private var pauseDuringCalls = true

    var body: some View {
        Form {
            Section {
                Toggle("Keep the audio as well as the transcript", isOn: $saveAudio)
                Toggle("Include the other side of calls", isOn: $includeOthers)
                HStack {
                    Text("Transcripts are saved in Documents › Alfred Transcripts").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Folder") {
                        try? FileManager.default.createDirectory(at: CaptureSettings.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(CaptureSettings.folder)
                    }
                }
            } header: {
                Text("Transcripts")
            } footer: {
                Text("Say “start transcribing” (or use the menu bar) to record a meeting or call; click the notch or say “Alfred, stop” to finish, then “summarise the meeting” for key points and to-dos in Notes. The other side of calls comes from the Mac's own audio and needs the Screen & System Audio Recording permission; lines are then labelled Me and Others. Recording only ever starts when you ask, and the notch shows a red dot throughout. Tell people you're recording.")
            }
            Section {
                Toggle("Stop listening for “Alfred” during calls", isOn: $pauseDuringCalls)
            } header: {
                Text("Calls")
            } footer: {
                Text("While another app uses the microphone (FaceTime, Zoom, Teams, a browser call, a phone call through your iPhone), Alfred doesn't listen. ⌥Space and the menu bar still work, so you can start a transcript during a call.")
            }
            Section("Dictation") {
                Text("“Dictate” types into the text field you're in; “take dictation” writes into a new note. Say “comma”, “full stop”, “question mark”, “new line” (or “go to a new line”), “new paragraph”, “scratch that”, and “stop dictation”. Typing needs Accessibility.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
