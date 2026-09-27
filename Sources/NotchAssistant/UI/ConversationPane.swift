import NotchAssistantCore
import SwiftUI

/// Talking with Alfred, and what it remembers.
struct ConversationPane: View {
    @AppStorage(Conversation.enabledKey) private var conversationOn = true
    @AppStorage(MemoryStore.enabledKey) private var memoryOn = true
    @State private var memories: [Memory] = MemoryStore.shared.all
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                Toggle("Talk with Alfred", isOn: $conversationOn)
            } footer: {
                Text("Say anything that isn't a command (“I had a long day at work”) and Alfred replies, then keeps listening for a few seconds so you can answer without saying “Alfred”. Say “that's all” or just stop talking to end. It runs on this Mac's own model: good company, but it has no internet and can be wrong.")
            }
            Section {
                Toggle("Remember our conversations", isOn: $memoryOn)
                if memories.isEmpty {
                    Text(memoryOn ? "Nothing remembered yet." : "Memory is off.").foregroundStyle(.secondary)
                }
                ForEach(memories) { memory in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: memory.kind == .fact ? "pin" : "text.bubble")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memory.text)
                            Text(memory.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            MemoryStore.shared.delete(memory.id)
                            memories = MemoryStore.shared.all
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Forget this")
                    }
                }
                if !memories.isEmpty {
                    Button("Forget Everything…", role: .destructive) { confirmForget = true }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("After a conversation, Alfred keeps a one-line summary and up to three facts (plans, people, preferences), only on this Mac. The most relevant few are brought up in later conversations. Say “what do you remember about me?”, “forget that”, or “forget everything”.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget everything Alfred remembers?", isPresented: $confirmForget) {
            Button("Forget Everything", role: .destructive) {
                MemoryStore.shared.deleteAll()
                memories = []
            }
        }
        .task {
            // Conversations end in the background; keep the list current.
            while !Task.isCancelled {
                memories = MemoryStore.shared.all
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
