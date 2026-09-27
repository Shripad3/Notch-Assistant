import NotchAssistantCore
import SwiftUI

/// Calling, texting and emailing: defaults and the Contacts permission.
struct MessagesPane: View {
    @AppStorage("messages.defaultApp") private var messagingApp = "messages"
    @AppStorage("email.defaultAccount") private var emailAccount = "gmail"
    @State private var contactsAllowed = ContactBook.isAllowed
    @State private var names = 0

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(contactsAllowed ? "Contacts: \(names) names ready" : "Contacts access not allowed yet")
                        .foregroundStyle(contactsAllowed ? .green : .secondary)
                    Spacer()
                    Button(contactsAllowed ? "Reload" : "Allow Contacts") {
                        Task {
                            await ContactBook.shared.load(ask: true)
                            refresh()
                        }
                    }
                }
            } header: {
                Text("People")
            } footer: {
                Text("Alfred finds people in the Contacts app, including nicknames and relations on your own card (“Amma”, “Bhaiya”). Names are given to speech recognition so unusual names are heard correctly; for Indian names and accents, set Accent to English (India) in Activation. Contacts never leave this Mac.")
            }
            Section {
                Picker("Texts go through", selection: $messagingApp) {
                    Text("Messages (iMessage or SMS via iPhone)").tag("messages")
                    Text("WhatsApp").tag("whatsapp")
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Messages")
            } footer: {
                Text("Messages: Alfred shows the text and sends it when you say “yes”. WhatsApp: it opens the chat with your message typed in, and you press Return. Say “on WhatsApp” to choose it for one message.")
            }
            Section {
                Picker("Emails open in", selection: $emailAccount) {
                    Text("Gmail").tag("gmail")
                    Text("Outlook on the web").tag("outlook")
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Email")
            } footer: {
                Text("Alfred opens a ready-made draft. With Gmail, say “send it” to send it from Alfred instead: this needs the Google sign-in in Settings › Calendar and the Gmail API turned on in your Google Cloud project. Say “from my uni account” or “from Gmail” to choose for one email.")
            }
            Section("Calls") {
                Text("“Call Amma” rings through your iPhone (turn on Calls from iPhone in FaceTime › Settings). “FaceTime Sam” and “FaceTime audio Sam” use FaceTime. Alfred always asks before calling.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    private func refresh() {
        contactsAllowed = ContactBook.isAllowed
        names = ContactBook.shared.namesForRecognition(limit: 10_000).count
    }
}
