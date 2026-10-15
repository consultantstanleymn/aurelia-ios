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
    /// Held here rather than in ContentView because reminders are a per-track setting and this is
    /// the only screen that edits them.
    @State private var reminders = Reminders()

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

                reminderSection

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
                DiagLog.event("settings.appear")
                savedKey = Keychain.read() ?? ""
                chatterboxURL = UserDefaults.standard.string(forKey: "chatterboxURL") ?? ""
                // Permission may have been granted in an earlier session, so the stored state is
                // not trustworthy on its own — ask the system before showing the toggles.
                Task { await reminders.refreshAuthorisation() }
            }
        }
    }

    // MARK: - reminders

    /// The Python tutor's reminder schedule, on the phone.
    ///
    /// Permission first and everything else after it: `UNUserNotificationCenter` drops requests
    /// made while unauthorised, silently, which leaves the learner with no reminders and nothing
    /// telling them why. So the toggles only appear once there is permission to honour them.
    @ViewBuilder
    private var reminderSection: some View {
        Section {
            switch reminders.authorisation {
            case .notDetermined:
                Button {
                    Task { await reminders.requestAuthorisation() }
                } label: {
                    Label("Turn on reminders", systemImage: "bell.badge")
                }
            case .denied:
                Label("Reminders are off for Aurelia in iOS Settings.", systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            case .authorized, .provisional, .ephemeral:
                ForEach(reminders.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { entry.enabled },
                            set: { enabled in
                                Task { await reminders.setEnabled(enabled, for: entry.id) }
                            }
                        )) {
                            Text(entry.track.displayName)
                        }
                        // When it next goes off, not what it is set to. A schedule the learner
                        // cannot picture is a schedule they stop trusting.
                        if entry.enabled {
                            HStack {
                                Text(nextFire(for: entry))
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textMuted)
                                Spacer()
                                DatePicker(
                                    "",
                                    selection: Binding(
                                        get: { date(for: entry.time) },
                                        set: { newValue in
                                            var updated = entry
                                            updated.time = Self.format(newValue)
                                            Task { await reminders.update(updated) }
                                        }
                                    ),
                                    displayedComponents: .hourAndMinute
                                )
                                .labelsHidden()
                            }
                        }
                    }
                }
            @unknown default:
                Text("Notification state is not one this build knows about.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Weekdays only, at the times the desktop tutor used. The next reminder is shown so you can see it is really booked.")
        }
    }

    private func nextFire(for entry: Reminders.Entry) -> String {
        guard let text = ReminderSchedule.describe(
            time: entry.time,
            weekdays: entry.days,
            now: Date()
        ) else {
            return "No days selected"
        }
        return "Next: \(text)"
    }

    /// "HH:mm" back into a Date for the picker, anchored to today because only the time is used.
    private func date(for text: String) -> Date {
        let (hour, minute) = ReminderSchedule.time(text)
        return Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: Date()
        ) ?? Date()
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - actions

    private func save() {
        DiagLog.event("settings.save", ["chars": draftKey.count])
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
        DiagLog.event("settings.clearKey")
        Keychain.clear()
        savedKey = ""
        status = .idle
        statusText = ""
    }

    /// Sends one short turn so "it works" means the model actually answered, not just that the
    /// socket opened.
    private func testConnection() async {
        DiagLog.event("settings.testConnection", ["provider": provider.provider])
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
            DiagLog.event("settings.testOK", ["chars": reply.count])
            status = .ok
            statusText = reply.isEmpty ? "Connected, but the model said nothing." : reply
        } catch {
            DiagLog.event("settings.testFailed", ["error": "\(error)"])
            status = .failed
            statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
#endif
