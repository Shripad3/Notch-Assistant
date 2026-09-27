import NotchAssistantCore
import SwiftUI

/// Which calendar Alfred reads, one at a time. Read-only.
struct CalendarPane: View {
    @State private var provider = CalendarProvider.current
    @State private var connected = CalendarProvider.current.isConnected
    @State private var working = false
    @State private var message: String?
    @AppStorage(CalendarProvider.googleClientIDKey) private var googleID = ""
    @AppStorage(CalendarProvider.outlookClientIDKey) private var outlookID = ""
    @State private var googleSecret = ""
    @AppStorage(TaskProvider.defaultsKey) private var taskProvider = TaskProvider.apple.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Read events from", selection: $provider) {
                    ForEach(CalendarProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: provider) { refresh() }
                HStack {
                    Text(status).font(.caption).foregroundStyle(connected ? .green : .secondary)
                    Spacer()
                    if let message { Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }
            } footer: {
                Text("Only one calendar is connected at a time; connecting one disconnects the others. Try “what's on my calendar tomorrow?”, “add lunch with Sam tomorrow at 1”, “move my dentist appointment to Friday” or “cancel my 3 o'clock”. Adding and moving can be undone (“undo that”); deleting always asks first; events with other people invited are left alone. Outlook is read-only.")
            }

            switch provider {
            case .apple: appleSection
            case .google: googleSection
            case .outlook: outlookSection
            }

            Section {
                Picker("Tasks and reminders go to", selection: $taskProvider) {
                    ForEach(TaskProvider.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Tasks")
            } footer: {
                Text(taskProvider == TaskProvider.google.rawValue
                    ? "Uses your Google sign-in above, and needs the Google Tasks API turned on in your Google Cloud project. Google Tasks keep a date but not a time, so Alfred rings timed reminders itself while it's running."
                    : "Reminders sync to your iPhone and alert at their time even when Alfred isn't running.")
                Text("Try “remind me to call Mum at 6”, “add milk to my to-do list”, “what's on my to-do list?”, “mark milk as done” or “delete the milk task”.")
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    private var status: String {
        if connected { return CalendarProvider.current == provider ? "Connected — Alfred reads \(provider.title)" : "Signed in, not in use" }
        return provider == .apple ? "Calendar access not granted yet" : "Not connected"
    }

    // MARK: Apple

    private var appleSection: some View {
        Section("Apple Calendar") {
            Text("Reads every calendar in the Calendar app. Google, Outlook/Exchange and iCloud calendars added in System Settings › Internet Accounts are included, so this is the simplest way to use them too.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(connected && CalendarProvider.current == .apple ? "Using Apple Calendar" : "Use Apple Calendar") {
                    run { 
                        guard await CalendarProvider.requestAppleAccess() else {
                            throw ToolError("Calendar access was refused; allow it in System Settings › Privacy & Security › Calendars")
                        }
                        try await CalendarProvider.apple.connect()
                    }
                }
                .disabled(working)
                Button("Internet Accounts…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                }
            }
        }
    }

    // MARK: Google

    private var googleSection: some View {
        Section {
            TextField("Client ID", text: $googleID, prompt: Text("….apps.googleusercontent.com"))
            SecureField("Client secret", text: $googleSecret, prompt: Text(CalendarProvider.hasGoogleSecret ? "Saved in the Keychain" : "GOCSPX-…"))
                .onSubmit { saveSecret() }
            signInButtons
        } header: {
            Text("Google Calendar")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("One-time setup, free (about 5 minutes):")
                Text("1. In Google Cloud Console, create a project and enable the **Google Calendar API**, the **Google Tasks API** and (to send emails from Alfred) the **Gmail API**.")
                Text("2. **OAuth consent screen**: choose External, fill in the app name and your email. Under Audience, set Publishing status to **In production** (otherwise Google signs you out every 7 days). Google will say the app is unverified; that's expected for your own app.")
                Text("3. **Credentials › Create credentials › OAuth client ID**, application type **Desktop app**.")
                Text("4. Paste the Client ID and Client secret here, press Return, then Sign In.")
                HStack {
                    Link("Enable the Calendar API", destination: URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")!)
                    Link("Enable the Tasks API", destination: URL(string: "https://console.cloud.google.com/apis/library/tasks.googleapis.com")!)
                    Link("Enable the Gmail API", destination: URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!)
                    Link("Credentials", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }
                Text("Alfred asks to see your calendars, add and change events, manage tasks, and send an email only after you say “send it”. Signed in before this update? Sign in again to allow adding events. The secret and your sign-in are stored in the Keychain.")
            }
        }
    }

    // MARK: Outlook

    private var outlookSection: some View {
        Section {
            TextField("Application (client) ID", text: $outlookID, prompt: Text("00000000-0000-0000-0000-000000000000"))
            signInButtons
        } header: {
            Text("Outlook")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("One-time setup, free (about 5 minutes), for Outlook.com or a work/school account:")
                Text("1. In Microsoft Entra, **App registrations › New registration**.")
                Text("2. Supported account types: **Accounts in any organizational directory and personal Microsoft accounts**.")
                Text("3. Redirect URI: platform **Public client/native (mobile & desktop)**, value **http://localhost**.")
                Text("4. **API permissions › Add › Microsoft Graph › Delegated › Calendars.Read**.")
                Text("5. Copy the **Application (client) ID** here, then Sign In. No secret is needed.")
                Link("App registrations", destination: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
                Text("A work account may need an administrator to allow the app. Alfred asks only for read access; your sign-in is stored in the Keychain.")
            }
        }
    }

    private var signInButtons: some View {
        HStack {
            Button(connected ? "Sign In Again" : "Sign In") {
                saveSecret()
                run { try await provider.connect() }
            }
            .disabled(working || (provider == .google ? googleID.isEmpty : outlookID.isEmpty))
            if connected {
                Button("Sign Out") { run { await provider.disconnect() } }
                    .disabled(working)
            }
            if working { ProgressView().controlSize(.small) }
        }
    }

    private func saveSecret() {
        guard !googleSecret.isEmpty else { return }
        CalendarProvider.setGoogleSecret(googleSecret)
        googleSecret = ""
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        message = nil
        Task {
            do {
                try await action()
            } catch {
                message = AssistantFailure(error).message
            }
            working = false
            refresh()
        }
    }

    private func refresh() {
        connected = provider.isConnected
    }
}
