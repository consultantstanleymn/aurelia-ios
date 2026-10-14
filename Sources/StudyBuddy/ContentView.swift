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
    @State private var draft = ""
    @State private var showingSettings = false
    @FocusState private var composerFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !tutor.isThinking
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
                board
                captions
                composer
            }
        }
        .preferredColorScheme(.light)
        .task {
            tutor.configure(brain: .deepSeek, transport: URLSessionBrainTransport())
            hasKey = !Keychain.effective().isEmpty
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView().onDisappear { hasKey = !Keychain.effective().isEmpty }
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 12) {
            crabMark
            VStack(alignment: .leading, spacing: 1) {
                Text(tutor.track.displayName)
                    .font(Theme.body(16)).fontWeight(.semibold)
                    .foregroundStyle(Theme.text)
                Text("Day \(tutor.day) of \(tutor.track.totalUnits) · \(tutor.mode.displayName)")
                    .font(Theme.label(11))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            Button { showingSettings = true } label: {
                Image(systemName: hasKey ? "gearshape" : "key.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hasKey ? Theme.textMuted : Theme.goldInk)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(hasKey ? Color.clear : Theme.goldPale))
            }
            .accessibilityLabel("Settings")
            if tutor.isSpeaking || tutor.isThinking {
                HStack(spacing: 7) {
                    SpeakingBars(isActive: tutor.isSpeaking || tutor.isThinking)
                    Text(tutor.isThinking ? "thinking" : "speaking")
                        .font(Theme.label(11))
                        .foregroundStyle(Theme.gold)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .glass(cornerRadius: 14)
                .transition(.opacity.combined(with: .scale(0.9)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var crabMark: some View {
        Image("aurelia")
            .resizable()
            .interpolation(.none)
            .frame(width: 34, height: 34)
            .accessibilityLabel("Aurelia")
    }

    // MARK: - board

    @ViewBuilder
    private var board: some View {
        if let item = tutor.board {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title.isEmpty ? item.kind.capitalized : item.title)
                    .font(Theme.label(11))
                    .foregroundStyle(Theme.gold)
                    .textCase(.uppercase)
                    .tracking(0.8)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(item.body)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glass(cornerRadius: 20, prominent: true)
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

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
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

            TextField("Tap the mic or type…", text: $draft, axis: .vertical)
                .font(Theme.body())
                .foregroundStyle(Theme.text)
                .lineLimit(1 ... 5)
                .focused($composerFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                }

            Button {
                let text = draft
                draft = ""
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
                if !hasKey && !draft.isEmpty {
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
