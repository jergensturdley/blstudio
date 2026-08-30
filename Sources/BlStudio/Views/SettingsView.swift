import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var choosingDir = false
    @State private var blCheckMessage: String?
    @State private var mmxCheckMessage: String?

    var body: some View {
        @Bindable var settingsStore = app.settingsStore
        let binding = $settingsStore.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "bl CLI") {
                    LabeledContent("Binary path") {
                        HStack {
                            TextField("auto-detect", text: binding.blBinaryPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Check") {
                                Task { await checkBinary() }
                            }
                        }
                        .frame(maxWidth: 420)
                    }
                    if let msg = blCheckMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Request timeout") {
                        Stepper(value: binding.requestTimeout, in: 60...3600, step: 30) {
                            Text("\(settingsStore.settings.requestTimeout)s")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                    LabeledContent("Poll interval") {
                        Stepper(value: binding.pollInterval, in: 1...15) {
                            Text("\(settingsStore.settings.pollInterval)s")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }

                Card(title: "mmx CLI") {
                    LabeledContent("Binary path") {
                        HStack {
                            TextField("auto-detect", text: mmxPathBinding)
                                .textFieldStyle(.roundedBorder)
                            Button("Check") {
                                Task { await checkMmx() }
                            }
                        }
                        .frame(maxWidth: 420)
                    }
                    if let msg = mmxCheckMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("mmx (mmx-cli) runs MiniMax video generation, including MiniMax-H3, and reads MiniMax token-plan quotas. MiniMax-H3 needs mmx 1.0.19 or newer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: "Images") {
                    LabeledContent("Library folder") {
                        HStack {
                            Text(settingsStore.settings.libraryURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Change…") { choosingDir = true }
                            Button("Reveal") {
                                FileActions.reveal([settingsStore.settings.libraryURL.path])
                            }
                        }
                    }
                    LabeledContent("Default size") {
                        Picker("", selection: binding.defaultSize) {
                            ForEach(["1:1", "3:4", "4:3", "16:9", "9:16"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                    Text("The Generate pane starts with this size; models and other parameters can be set per run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: "Providers") {
                    ForEach(KeyProvider.allCases, id: \.self) { p in
                        Toggle(isOn: providerBinding(p)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.label).font(.callout)
                                Text(providerNote(p))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    Text("Turning a provider off hides it from the Generate, Video, and Speech pickers. Stored keys are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: "Per-provider API key") {
                    Text("Pick which stored key each provider uses. Add keys in the API Keys tab. A provider with no stored keys shows “— (none)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(KeyProvider.allCases, id: \.self) { p in
                        keyPickerRow(p)
                    }
                }

                Card(title: "Defaults") {
                    LabeledContent("Image model") {
                        SuggestingField(title: "Image model", text: binding.defaultImageModel,
                                        suggestions: ModelCatalog.imageModels)
                            .frame(maxWidth: 320)
                    }
                    LabeledContent("Chat model") {
                        SuggestingField(title: "Chat model", text: binding.defaultChatModel,
                                        suggestions: ModelCatalog.chatModels)
                            .frame(maxWidth: 320)
                    }
                    Text("Leave empty to use bl's built-in defaults. Per-run values in Generate/Chat override these.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: "About") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("App").foregroundStyle(.secondary)
                            Text("BlStudio is a desktop client for the bl (Bailian) CLI")
                        }
                        GridRow {
                            Text("CLI").foregroundStyle(.secondary)
                            Text(app.cliVersion ?? "unknown")
                        }
                        GridRow {
                            Text("Data").foregroundStyle(.secondary)
                            Text(AppPaths.appSupport.path).textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding()
        }
        .fileImporter(isPresented: $choosingDir, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                settingsStore.settings.imageLibraryDir = url.path
                url.stopAccessingSecurityScopedResource()
            }
        }
        .onChange(of: settingsStore.settings.blBinaryPath) { _, _ in
            app.applySettings()
        }
        .onChange(of: settingsStore.settings.mmxBinaryPath) { _, _ in
            app.applySettings()
        }
        .onAppear {
            app.generate.size = settingsStore.settings.defaultSize
            if app.generate.model.isEmpty {
                app.generate.model = settingsStore.settings.defaultImageModel
            }
            if app.chat.model.isEmpty {
                app.chat.model = settingsStore.settings.defaultChatModel
            }
        }
    }

    private func checkBinary() async {
        app.applySettings()
        do {
            let v = try await app.client.cliVersion()
            blCheckMessage = "Found: \(v)"
        } catch {
            blCheckMessage = error.localizedDescription
        }
    }

    private func checkMmx() async {
        app.applySettings()
        do {
            let v = try await app.mmx.cliVersion()
            if MmxClient.versionAtLeast(v, MmxClient.h3MinVersion) {
                mmxCheckMessage = "Found: mmx \(v)"
            } else {
                mmxCheckMessage = "Found: mmx \(v). MiniMax-H3 needs \(MmxClient.h3MinVersion) or newer; run `mmx update`."
            }
        } catch {
            mmxCheckMessage = error.localizedDescription
        }
    }

    private var mmxPathBinding: Binding<String> {
        Binding(
            get: { app.settingsStore.settings.mmxBinaryPath ?? "" },
            set: { app.settingsStore.settings.mmxBinaryPath = $0.isEmpty ? nil : $0 }
        )
    }

    private func providerBinding(_ p: KeyProvider) -> Binding<Bool> {
        Binding(
            get: { app.settingsStore.isProviderEnabled(p) },
            set: { app.settingsStore.setProviderEnabled(p, enabled: $0) }
        )
    }

    private func providerNote(_ p: KeyProvider) -> String {
        switch p {
        case .bailian: return "Images, video, and chat via the bl CLI"
        case .minimax: return "Images, video, music, and speech"
        case .pollinations: return "Free, keyless images"
        case .gemini: return "Images (uses credits)"
        case .fish: return "Speech (Fish Audio)"
        case .cloudflare: return "Free-tier images (Workers AI FLUX)"
        case .huggingface: return "Images via inference providers"
        case .meta: return "Meta Muse Image ($0.01 per image)"
        }
    }

    /// A single per-provider key picker row. Shows the provider label, the
    /// currently active key (if any), and a menu to switch keys.
    @ViewBuilder
    private func keyPickerRow(_ p: KeyProvider) -> some View {
        let candidates = app.keysStore.keys(for: p)
        let preferredId = app.settingsStore.preferredKeyId(for: p)
        let activeId = preferredId ?? candidates.first?.id
        let activeLabel = candidates.first(where: { $0.id == activeId })?.label
        let activeMasked = candidates.first(where: { $0.id == activeId })?.masked

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.label).font(.callout)
                if let label = activeLabel {
                    Text("Active: \(label) (\(activeMasked ?? ""))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No key for this provider yet")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Picker("", selection: Binding(
                get: { activeId },
                set: { newId in
                    app.settingsStore.setPreferredKeyId(newId, for: p)
                }
            )) {
                Text("— (use first available)").tag(UUID?.none)
                ForEach(candidates) { key in
                    Text("\(key.label) (\(key.masked))").tag(UUID?.some(key.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 320)
            .disabled(candidates.isEmpty)
        }
    }
}
