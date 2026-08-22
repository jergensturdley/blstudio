import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var choosingDir = false
    @State private var blCheckMessage: String?

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
                            Text("BlStudio — a desktop client for the bl (Bailian) CLI")
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
}
