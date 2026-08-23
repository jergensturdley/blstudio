import SwiftUI

struct SpeechView: View {
    @Environment(AppState.self) private var app

    @State private var runningTask: Task<Void, Never>?
    @State private var previewPath: String?

    var body: some View {
        @Bindable var sp = app.speech

        HStack(spacing: 0) {
            // MARK: Left (text & options)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Text") {
                        TextEditor(text: $sp.text)
                            .font(.body)
                            .frame(minHeight: 130)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                        HStack {
                            Spacer()
                            Button("Clear") { sp.text = "" }
                                .disabled(sp.text.isEmpty)
                        }
                        .controlSize(.small)
                    }

                    Card(title: "Options") {
                        LabeledContent("Provider") {
                            Picker("", selection: $sp.provider) {
                                Text("MiniMax").tag(KeyProvider.minimax.rawValue)
                                Text("Fish Audio").tag(KeyProvider.fish.rawValue)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }

                        if sp.isFish {
                            fishOptions(sp)
                        } else {
                            minimaxOptions(sp)
                        }
                    }

                    HStack {
                        Button {
                            previewPath = nil
                            runningTask = Task { await sp.generate() }
                        } label: {
                            Label("Generate speech", systemImage: "waveform")
                                .frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!sp.canRun)

                        if sp.phase == .running {
                            Button("Cancel", role: .cancel) {
                                runningTask?.cancel()
                            }
                        }
                    }

                    PhaseFooter(phase: sp.phase, progressLine: sp.progressLine)
                }
                .padding()
            }
            .frame(minWidth: 430, maxWidth: 520)
            .onChange(of: sp.provider) { _, _ in previewPath = nil }

            Divider()

            // MARK: Right (results)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let currentPath = previewPath ?? sp.lastSavedPath
                    if let path = currentPath {
                        Card(title: previewPath != nil ? "Preview" : "Latest speech") {
                            AudioPlayerCard(path: path)
                        }
                    }

                    let recent = app.history.entries
                        .filter { $0.kind == .speech && !$0.savedPaths.isEmpty }
                        .prefix(8)
                    if !recent.isEmpty {
                        Card(title: "Recent speech") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(recent)) { entry in
                                    AudioRow(
                                        title: entry.prompt.isEmpty
                                            ? URL(fileURLWithPath: entry.savedPaths[0]).lastPathComponent
                                            : String(entry.prompt.prefix(70)),
                                        subtitle: entry.model ?? "",
                                        path: entry.savedPaths[0]
                                    ) {
                                        previewPath = entry.savedPaths[0]
                                    }
                                }
                            }
                        }
                    }

                    if currentPath == nil && recent.isEmpty {
                        ContentUnavailableView(
                            "No speech yet",
                            systemImage: "waveform.badge.mic",
                            description: Text("Type some text on the left and hit Generate speech.\nAudio is saved to your library folder.")
                        )
                        .padding(.top, 60)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func minimaxOptions(_ speechModel: SpeechModel) -> some View {
        @Bindable var sp = speechModel
        LabeledContent("Model") {
            Picker("", selection: $sp.model) {
                ForEach(ModelCatalog.speechModels, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 300)
        }
        LabeledContent("Voice") {
            SuggestingField(title: "Voice", text: $sp.voice,
                            suggestions: ModelCatalog.ttsVoices)
                .frame(maxWidth: 300)
        }
        LabeledContent("Speed") {
            HStack {
                Slider(value: $sp.speed, in: 0.5...2.0, step: 0.05)
                    .frame(maxWidth: 200)
                Text(String(format: "%.2fx", sp.speed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
        LabeledContent("Emotion") {
            Picker("", selection: $sp.emotion) {
                ForEach(ModelCatalog.ttsEmotions, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 300)
        }

        VStack(alignment: .leading, spacing: 2) {
            Text("MiniMax text-to-audio supports many system voices; you can also type a custom voice id.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !app.miniMaxConfigured {
                Text("No MiniMax key yet. Add one in the API Keys tab with provider MiniMax.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func fishOptions(_ speechModel: SpeechModel) -> some View {
        @Bindable var sp = speechModel
        LabeledContent("Voice model") {
            TextField("reference id (optional)", text: $sp.referenceId)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
        }

        VStack(alignment: .leading, spacing: 2) {
            Text("Fish Audio streams the audio back directly. Leave the voice model empty to use your account default, or paste a reference id from fish.audio.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !app.fishConfigured {
                Text("No Fish Audio key yet. Add one in the API Keys tab with provider Fish Audio.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
