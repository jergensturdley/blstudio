import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var chat = app.chat

        VStack(spacing: 0) {
            // Options bar
            HStack(spacing: 10) {
                SuggestingField(title: "Model", text: $chat.model,
                                suggestions: ModelCatalog.chatModels)
                    .frame(maxWidth: 320)

                Stepper(value: $chat.maxTokens, in: 256...32768, step: 256) {
                    Text("max tokens: \(chat.maxTokens)")
                        .font(.caption)
                        .monospacedDigit()
                }
                .fixedSize()

                Spacer()

                Button("Clear chat") { chat.messages = [] }
                    .disabled(chat.messages.isEmpty)
            }
            .padding(10)
            .background(.bar)

            Divider()

            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty {
                            ContentUnavailableView(
                                "Quick chat",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Ask anything — great for prompt brainstorming,\ncaptions, and idea iteration before generating.")
                            )
                            .padding(.top, 60)
                        }
                        ForEach(chat.messages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                        if chat.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .id("busy")
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation {
                        if let last = chat.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: chat.busy) { _, busy in
                    if busy { proxy.scrollTo("busy", anchor: .bottom) }
                }
            }

            Divider()

            // Composer
            VStack(spacing: 8) {
                DisclosureGroup("System prompt") {
                    TextEditor(text: $chat.systemPrompt)
                        .font(.callout)
                        .frame(minHeight: 50, maxHeight: 100)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
                .font(.caption)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message… (⌘↩ to send)", text: $chat.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .onKeyPress(keys: [KeyEquivalent.return], phases: .down) { press in
                            if press.modifiers.contains(.command) {
                                send()
                                return .handled
                            }
                            return .ignored
                        }

                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!chat.canSend)
                }
            }
            .padding(10)
            .background(.bar)
        }
        .onAppear { inputFocused = true }
    }

    private func send() {
        guard app.chat.canSend else { return }
        Task { await app.chat.send() }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.content)
                    .textSelection(.enabled)
                    .foregroundStyle(message.error ? .red : .primary)
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(reasoning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
                if message.role == .assistant, let p = message.promptTokens, let c = message.completionTokens {
                    Text("\(message.model ?? "") · ↑\(Fmt.tokens(p)) ↓\(Fmt.tokens(c)) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(message.role == .user
                          ? Color.accentColor.opacity(0.18)
                          : Color.gray.opacity(0.12))
            )
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}
