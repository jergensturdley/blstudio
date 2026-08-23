import SwiftUI

struct KeysView: View {
    @Environment(AppState.self) private var app

    @State private var newLabel = ""
    @State private var newSecret = ""
    @State private var newProvider: KeyProvider = .bailian
    @State private var errorMessage: String?
    @State private var testResult: [UUID: String] = [:]
    @State private var testing: UUID?

    private var newKeyPlaceholder: String {
        switch newProvider {
        case .minimax: return "eyJ…"
        case .gemini: return "AIza…"
        default: return "sk-…"
        }
    }

    var body: some View {
        @Bindable var keys = app.keysStore

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "API keys") {
                    Text("Keys are stored in the macOS Keychain. Bailian keys are passed to bl via --api-key; when none is selected, BlStudio uses the active bl CLI profile. MiniMax keys are used directly for MiniMax image generation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if keys.keys.isEmpty {
                        ContentUnavailableView(
                            "No keys stored",
                            systemImage: "key.horizontal",
                            description: Text("Add a DashScope / Bailian API key below, or rely on the CLI default profile (bl auth login).")
                        )
                        .padding(.vertical, 10)
                    }

                    ForEach(keys.keys) { key in
                        HStack(spacing: 10) {
                            Image(systemName: keys.activeKeyId == key.id
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(keys.activeKeyId == key.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(key.label).font(.callout.bold())
                                    Text(key.resolvedProvider.label)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(key.isMiniMax ? Color.purple.opacity(0.18) : Color.accentColor.opacity(0.14)))
                                }
                                Text("\(key.masked) · added \(Fmt.shortDate.string(from: key.createdAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            if let test = testResult[key.id] {
                                Text(test)
                                    .font(.caption)
                                    .foregroundStyle(test.hasPrefix("OK") ? .green : .red)
                                    .lineLimit(1)
                            }

                            Button {
                                Task { await testKey(key) }
                            } label: {
                                if testing == key.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Test")
                                }
                            }
                            .disabled(testing != nil)

                            Button {
                                keys.activeKeyId = key.id
                            } label: { Text("Select") }
                            .disabled(keys.activeKeyId == key.id)

                            Button(role: .destructive) {
                                keys.remove(key.id)
                            } label: { Image(systemName: "trash") }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(keys.activeKeyId == key.id ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                        )
                    }
                }

                Card(title: "Add a key") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Label").foregroundStyle(.secondary)
                            TextField("e.g. work, personal", text: $newLabel)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("API key").foregroundStyle(.secondary)
                            SecureField(newKeyPlaceholder, text: $newSecret)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Provider").foregroundStyle(.secondary)
                            Picker("", selection: $newProvider) {
                                ForEach(KeyProvider.allCases.filter { $0.needsKey }, id: \.self) { p in
                                    Text(p.label).tag(p)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 340, alignment: .leading)
                        }
                    }
                    HStack {
                        Button {
                            addKey()
                        } label: {
                            Label("Add key", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newSecret.trimmingCharacters(in: .whitespaces).count < 8)

                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Card(title: "CLI default profile") {
                    if let auth = app.authStatus {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow {
                                Text("Authenticated").foregroundStyle(.secondary)
                                Text((auth.authenticated ?? false) ? "yes" : "no")
                            }
                            GridRow {
                                Text("Profile").foregroundStyle(.secondary)
                                Text(auth.config ?? "-")
                            }
                            GridRow {
                                Text("API key").foregroundStyle(.secondary)
                                Text(auth.api_key?.masked ?? "-")
                            }
                            GridRow {
                                Text("Base URL").foregroundStyle(.secondary)
                                Text(auth.api_key?.base_url ?? "-").lineLimit(1).truncationMode(.middle)
                            }
                            GridRow {
                                Text("Console").foregroundStyle(.secondary)
                                Text(auth.console?.masked.map { "\($0) (\(auth.console?.region ?? "?"))" } ?? "not logged in")
                            }
                        }
                        .font(.caption)
                        .textSelection(.enabled)

                        Button("Re-check status") {
                            Task { await app.refreshStatus() }
                        }
                        .controlSize(.small)
                        .padding(.top, 4)
                    } else {
                        Text("Status not loaded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    private func addKey() {
        errorMessage = nil
        do {
            _ = try app.keysStore.add(label: newLabel, secret: newSecret, provider: newProvider)
            newLabel = ""
            newSecret = ""
            newProvider = .bailian
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Verifies a key with the smallest possible request. Bailian keys send a
    /// one-token chat ping; MiniMax keys hit a free file-retrieve endpoint.
    private func testKey(_ key: APIKeyMeta) async {
        testing = key.id
        testResult[key.id] = nil
        defer { testing = nil }
        guard let secret = app.keysStore.secret(for: key.id) else {
            testResult[key.id] = "Keychain read failed"
            return
        }
        do {
            if key.isMiniMax {
                let msg = try await app.minimax.validate(apiKey: secret)
                testResult[key.id] = msg
            } else if key.isGemini {
                let msg = try await app.gemini.validate(apiKey: secret)
                testResult[key.id] = msg
            } else {
                var req = ChatRequest(message: "ping")
                req.maxTokens = 1
                let completion = try await app.client.textChat(req, apiKey: secret, timeoutSeconds: 60)
                testResult[key.id] = "OK · \(completion.model ?? "model")"
            }
        } catch {
            testResult[key.id] = String(error.localizedDescription.prefix(80))
        }
    }
}
