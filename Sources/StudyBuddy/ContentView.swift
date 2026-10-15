#if canImport(SwiftUI)
import SwiftUI
import StudyBuddyCore

/// The tutor.
///
/// One screen, because a study session is one conversation. The board appears above the captions
/// only when the tutor has put something on it, and the composer is always reachable — the whole
/// interaction is talk, reply, talk.
struct ContentView: View {
    @State private var tutor = TutorController(voice: SystemVoice())
    @State private var ears = SpeechRecognizer()
    /// Drives a single warning in the header until the key is added. Hidden once it is set, and
    /// never a modal, because the tutor is otherwise ready to go.
    @State private var hasKey = false
    /// The composer's text and the rules for putting speech into it. The rules are in Core so they
    /// are tested; this only binds them to a text field.
    @State private var composer = ComposerBuffer()
    @State private var showingSettings = false
    @FocusState private var composerFocused: Bool

    private var canSend: Bool {
        // Sending waits until the recogniser has stopped. The composer is already showing the live
        // transcript while it listens, so nothing is hidden by waiting — and stopping on send
        // instead would let the settled text arrive a moment after the send and pre-fill the
        // composer with the same words, one tap away from being sent twice.
        composer.isSendable && !tutor.isThinking && ears.state != .listening
    }

    private var draft: Binding<String> {
        Binding(
            get: { composer.draft },
            set: { composer.userTyped($0) }
        )
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            // A gold pool behind everything, matching the app icon so the two read as one object.
            RadialGradient(
                colors: [Theme.gold.opacity(0.22), .clear],
                center: .init(x: 0.5, y: 0.06),
                startRadius: 10,
                endRadius: 460
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                // The reason the mic is not working used to be written into the recogniser and
                // never drawn, so a denied permission looked exactly like a dead button.
                micNotice
                board
                captions
                composerBar
            }
        }
        .preferredColorScheme(.light)
        .task {
            DiagLog.event("app.task")
            await tutor.prepare()
            DiagLog.event("app.bundle", ["id": Bundle.main.bundleIdentifier ?? "nil"])
            DiagLog.event("app.logPath", ["path": DiagLog.path])
            DiagLog.event("app.hasKey", ["key": !Keychain.effective().isEmpty])
            DiagLog.event("app.tracks", ["count": Track.allCases.count])
            tutor.configure(brain: .deepSeek, transport: URLSessionBrainTransport())
            hasKey = !Keychain.effective().isEmpty
            StartupSelfTest.runIfNeeded(
                ears: ears,
                tutor: tutor,
                apiKey: Keychain.effective()
            )
        }
        // The recogniser and the composer are separate pieces of state, and nothing used to join
        // them: the microphone worked, the log filled with final transcripts, and the text field
        // stayed empty. These three lines are the whole join.
        .onChange(of: ears.transcript) { _, text in
            composer.heard(text)
        }
        .onChange(of: ears.finalText) { _, text in
            composer.settled(text)
        }
        .onChange(of: ears.state) { _, state in
            switch state {
            case .listening:
                composer.beginListening()
            case .idle:
                // Stopping is how a turn ends: the settled text stays put, editable, until it is
                // sent. Nothing is auto-sent, because recognition gets the technical terms wrong
                // and the correction is the point.
                composer.settled(ears.finalText)
            case .unavailable:
                break
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView().onDisappear { hasKey = !Keychain.effective().isEmpty }
        }
    }

    // MARK: - header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                crabMark
                VStack(alignment: .leading, spacing: 1) {
                    Text(tutor.track.displayName)
                        .font(Theme.body(16)).fontWeight(.semibold)
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Text("\(tutor.track.unitName) \(tutor.day) of \(tutor.track.totalUnits)")
                        if tutor.streakDays > 0 {
                            Text("·").foregroundStyle(Theme.gold)
                            Text("\(tutor.streakDays) day streak")
                        }
                        if tutor.coveredCount > 0 {
                            Text("·").foregroundStyle(Theme.gold)
                            Text("\(tutor.coveredCount) covered")
                        }
                    }
                    .font(Theme.label(11))
                    .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 8)
                if tutor.isSpeaking || tutor.isThinking {
                    HStack(spacing: 7) {
                        SpeakingBars(isActive: tutor.isSpeaking || tutor.isThinking)
                        Text(tutor.isThinking ? "thinking" : "speaking")
                            .font(Theme.label(11))
                            .foregroundStyle(Theme.goldInk)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .glass(cornerRadius: 14)
                    .transition(.opacity.combined(with: .scale(0.9)))
                }
                Button {
                    DiagLog.event("ui.settingsTapped")
                    showingSettings = true
                } label: {
                    Image(systemName: hasKey ? "gearshape" : "key.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hasKey ? Theme.textMuted : Theme.goldInk)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(hasKey ? Color.clear : Theme.goldPale))
                }
                .accessibilityLabel("Settings")
            }

            // Track and day, because the content store has 238 days behind them and there was no
            // way to reach any of it.
            HStack(spacing: 8) {
                ForEach(Track.allCases, id: \.rawValue) { option in
                    Button {
                        Task { await tutor.select(track: option) }
                    } label: {
                        Text(option == .aws ? "AWS" : option == .lsat ? "LSAT" : "Quant")
                            .font(Theme.label(12))
                            .foregroundStyle(option == tutor.track ? Theme.background : Theme.textMuted)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background {
                                Capsule().fill(option == tutor.track ? Theme.gold : Color.clear)
                            }
                    }
                    .accessibilityLabel(option.displayName)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await tutor.select(day: tutor.day - 1) }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                }
                .disabled(tutor.day <= 1)
                Text("\(tutor.day)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 26)
                Button {
                    Task { await tutor.select(day: tutor.day + 1) }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
                .disabled(tutor.day >= tutor.track.totalUnits)
            }
            .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var crabMark: some View {
        Image("aurelia")
            .resizable()
            .interpolation(.none)
            .frame(width: 34, height: 34)
            .accessibilityLabel("Aurelia")
    }

    @ViewBuilder
    private var micNotice: some View {
        if case let .unavailable(reason) = ears.state {
            HStack(spacing: 10) {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(Theme.goldInk)
                Text(reason)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.goldPale)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
    }

    // MARK: - board

    @ViewBuilder
    private var board: some View {
        if let shape = tutor.board {
            BoardView(shape: shape, focus: tutor.boardFocus) {
                tutor.clearBoard()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - captions

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if tutor.captions.isEmpty { emptyState }
                    ForEach(tutor.captions) { caption in
                        CaptionRow(caption: caption).id(caption.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: tutor.captions.count) {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 40)
            Image("crab")
                .resizable().interpolation(.none)
                .frame(width: 86, height: 76)
                .opacity(0.95)
            Text("Ready when you are.")
                .font(Theme.display(24))
                .foregroundStyle(Theme.text)
            Text("Talk or type. Say what you got wrong and I will start there.")
                .font(Theme.body(15))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - composer

    private var composerBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                DiagLog.event("ui.micTapped")
                ears.toggle()
            } label: {
                Image(systemName: ears.state == .listening ? "waveform" : "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ears.state == .listening ? Theme.background : Theme.goldInk)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(ears.state == .listening ? Theme.gold : Theme.goldPale))
                    .overlay {
                        // A ring that grows while listening, so it is obvious the mic is open even
                        // when the transcript has not started filling yet.
                        if ears.state == .listening {
                            Circle()
                                .stroke(Theme.gold.opacity(0.5), lineWidth: 2)
                                .scaleEffect(1.18)
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: ears.state == .listening)
            }
            .accessibilityLabel(ears.state == .listening ? "Stop listening" : "Talk to Aurelia")

            TextField(
                ears.state == .listening ? "Listening…" : "Tap the mic or type…",
                text: draft,
                axis: .vertical
            )
                .font(Theme.body())
                .foregroundStyle(Theme.text)
                .lineLimit(1 ... 5)
                .focused($composerFocused)
                // Read-only while listening. It is being written many times a second by the
                // recogniser, and a field that fights the typist is worse than one that waits.
                // Editable the moment it stops, which is where correcting a misheard term happens.
                .disabled(ears.state == .listening)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(ears.state == .listening ? 0.10 : 0.06))
                }
                .overlay {
                    // The field itself says the app is hearing something, so an empty composer is
                    // never ambiguous: either it is waiting for you, or it is listening.
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(ears.state == .listening ? Theme.gold.opacity(0.5) : .clear, lineWidth: 1)
                }
                .animation(.easeOut(duration: 0.18), value: ears.state == .listening)

            Button {
                let text = composer.takeForSending()
                DiagLog.event("ui.send", ["chars": text.count])
                Task { await tutor.send(text, apiKey: Keychain.effective()) }
            } label: {
                Image(systemName: tutor.isThinking ? "ellipsis" : "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.gold))
            }
            .disabled(!canSend)
            .overlay(alignment: .bottom) {
                // Nudge in place rather than blocking the send, so the reason is visible without
                // a modal the first time it happens.
                if !hasKey && composer.isSendable {
                    Text("Add a key")
                        .font(Theme.label(10))
                        .foregroundStyle(Theme.goldInk)
                        .offset(y: 26)
                }
            }
            .opacity(canSend ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}
#endif
