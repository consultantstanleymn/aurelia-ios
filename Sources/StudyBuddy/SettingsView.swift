#if canImport(SwiftUI)
import SwiftUI
import StudyBuddyCore

/// Where the brain and the voice get pointed.
///
/// Both of them need something the app cannot supply on its own — a key, and a machine with a
/// GPU — so both live here rather than being hidden as constants. The key is written to the
/// Keychain and never to a file or the bundle.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Held in memory only while this sheet is open. Never persisted in this property.
    @State private var draftKey = ""
    @State private var savedKey = ""
    @State private var provider: BrainConfiguration = .deepSeek
    @State private var chatterboxURL = ""
    @State private var status: Status = .idle
    @State private var statusText = ""

    enum Status: Equatable { case idle, testing, ok, failed }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $provider) {
                        Text("DeepSeek").tag(BrainConfiguration.deepSeek)
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Model", value: provider.model)
                    Text(provider.note)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                } header: {
                    Text("Brain")
                }

                Section {
                    SecureField("API key", text: $draftKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        save()
                    } label: {
                        Label("Save key to Keychain", systemImage: "key.fill")
                    }
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !savedKey.isEmpty {
                        LabeledContent("In Keychain", value: "••••••••" + String(savedKey.suffix(4)))
                        Text("This overrides the built-in key, so you can rotate without a rebuild.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                        Button(role: .destructive) { clear() } label: {
                            Label("Remove from Keychain", systemImage: "trash")
                        }
                    } else if !InjectedAPIKey.value.isEmpty {
                        LabeledContent("Key", value: "built into this build")
                        Text("Baked in by tools/inject-key.sh. Nothing to paste. Run that script with --clear, or add a key above, to change it.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    } else {
                        Text("No key anywhere. Run bash tools/inject-key.sh and rebuild, or paste one above.")
                            .font(.footnote)
                            .foregroundStyle(Theme.goldInk)
                    }
                } header: {
                    Text("Key")
                } footer: {
                    Text("Stored in the iOS Keychain. It is never written to this app's files and never included in a build.")
                }

                Section {
                    TextField("http://host:8787/v1/chat/completions", text: $chatterboxURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.footnote, design: .monospaced))
                    Text("Only needed for the Chatterbox voice. 350M parameters will not run on a phone, so the voice is synthesized on another machine and streamed here.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                } header: {
                    Text("Voice")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if status == .testing { ProgressView() }
                        }
                    }
                    .disabled(status == .testing || Keychain.effective().isEmpty)

                    if status == .ok {
                        Label(statusText, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if status == .failed {
                        Label(statusText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Check")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear {
                savedKey = Keychain.read() ?? ""
                chatterboxURL = UserDefaults.standard.string(forKey: "chatterboxURL") ?? ""
            }
        }
    }

    // MARK: - actions

    private func save() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.save(key)
            savedKey = Keychain.read() ?? ""
            draftKey = ""
            status = .ok
            statusText = "Key saved to the Keychain."
        } catch {
            status = .failed
            statusText = error.localizedDescription
        }
    }

    private func clear() {
        Keychain.clear()
        savedKey = ""
        status = .idle
        statusText = ""
    }

    /// Sends one short turn so "it works" means the model actually answered, not just that the
    /// socket opened.
    private func testConnection() async {
        status = .testing
        statusText = ""
        let session = TutorSession(
            configuration: provider,
            transport: URLSessionBrainTransport(),
            prompts: PromptBuilder()
        )
        do {
            var reply = ""
            for try await event in await session.send(
                "Reply with the single word: connected",
                apiKey: Keychain.effective(),
                context: StudyContext()
            ) {
                if case let .speech(text) = event { reply += text }
            }
            status = .ok
            statusText = reply.isEmpty ? "Connected, but the model said nothing." : reply
        } catch {
            status = .failed
            statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
#endif
