import SwiftUI

struct KeysView: View {
    @Environment(AppState.self) private var app

    @State private var newLabel = ""
    @State private var newSecret = ""
    @State private var newProvider: KeyProvider = .bailian
    @State private var newAccountId = ""
    @State private var errorMessage: String?
    @State private var testResult: [UUID: String] = [:]
    @State private var testing: UUID?

    private var newKeyPlaceholder: String {
        switch newProvider {
        case .minimax: return "eyJ…"
        case .gemini: return "AIza…"
        case .fish: return "Fish Audio API key"
        case .cloudflare: return "Cloudflare API token"
        case .huggingface: return "hf…"
        default: return "sk-…"
        }
    }

    private func keyCaption(_ key: APIKeyMeta) -> String {
        var parts = [key.masked, "added \(Fmt.shortDate.string(from: key.createdAt))"]
        if let acct = key.accountId, !acct.isEmpty {
            let label = key.isCloudflare ? "account" : "provider"
            parts.append("\(label): \(acct)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        @Bindable var keys = app.keysStore

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "API keys") {
                    Text("Keys are stored in the macOS Keychain. Pick which key each provider uses in Settings → Per-provider API key (when a provider has more than one key). With no preference set, the first stored key of that provider is used.")
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
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(key.label).font(.callout.bold())
                                    Text(key.resolvedProvider.label)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(key.isMiniMax ? Color.purple.opacity(0.18) : Color.accentColor.opacity(0.14)))
                                    if app.settingsStore.preferredKeyId(for: key.resolvedProvider) == key.id {
                                        Text("preferred for this provider")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text(keyCaption(key))
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

                            Button(role: .destructive) {
                                keys.remove(key.id)
                            } label: { Image(systemName: "trash") }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
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
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 340, alignment: .leading)
                        }
                        if newProvider == .cloudflare {
                            GridRow {
                                Text("Account ID").foregroundStyle(.secondary)
                                TextField("Cloudflare account id", text: $newAccountId)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        if newProvider == .huggingface {
                            GridRow {
                                Text("Provider").foregroundStyle(.secondary)
                                TextField("Inference provider override (blank: auto)", text: $newAccountId)
                                    .textFieldStyle(.roundedBorder)
                            }
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
        if newProvider == .cloudflare
            && newAccountId.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "Cloudflare keys need an Account ID."
            return
        }
        do {
            _ = try app.keysStore.add(label: newLabel, secret: newSecret, provider: newProvider,
                                      accountId: newAccountId)
            newLabel = ""
            newSecret = ""
            newAccountId = ""
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
            } else if key.isFish {
                let msg = try await app.fish.validate(apiKey: secret)
                testResult[key.id] = msg
            } else if key.isCloudflare {
                let msg = try await app.cloudflare.validate(apiKey: secret, accountId: key.accountId ?? "")
                testResult[key.id] = msg
            } else if key.isHuggingFace {
                let msg = try await app.huggingface.validate(apiKey: secret)
                testResult[key.id] = msg
            } else if key.isMeta {
                let msg = try await app.metaMuse.validate(apiKey: secret)
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
