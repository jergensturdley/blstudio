import SwiftUI

struct MusicView: View {
    @Environment(AppState.self) private var app

    @State private var runningTask: Task<Void, Never>?
    @State private var previewPath: String?

    var body: some View {
        @Bindable var mus = app.music

        HStack(spacing: 0) {
            // MARK: Left (prompt & options)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Song description") {
                        TextEditor(text: $mus.prompt)
                            .font(.body)
                            .frame(minHeight: 130)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                        Text("Describe the song's style: genre, mood, tempo, instruments, vocals. Add lyrics separately below if you want singing.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Clear") { mus.prompt = "" }
                                .disabled(mus.prompt.isEmpty)
                        }
                        .controlSize(.small)
                    }

                    Card(title: "Lyrics (optional)") {
                        TextEditor(text: $mus.lyrics)
                            .font(.body)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                        Text("Leave empty for an instrumental. Use [verse] and [chorus] to mark sections.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Card(title: "Options") {
                        LabeledContent("Model") {
                            Picker("", selection: $mus.model) {
                                ForEach(ModelCatalog.musicModels, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("MiniMax composes full songs with vocals. Generation usually takes about a minute.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !app.miniMaxConfigured {
                                Text("No MiniMax key yet. Add one in the API Keys tab with provider MiniMax.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    HStack {
                        Button {
                            previewPath = nil
                            runningTask = Task { await mus.generate() }
                        } label: {
                            Label("Generate music", systemImage: "music.note")
                                .frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!mus.canRun)

                        if mus.phase == .running {
                            Button("Cancel", role: .cancel) {
                                runningTask?.cancel()
                            }
                        }
                    }

                    PhaseFooter(phase: mus.phase, progressLine: mus.progressLine)
                }
                .padding()
            }
            .frame(minWidth: 430, maxWidth: 520)

            Divider()

            // MARK: Right (results)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let currentPath = previewPath ?? mus.lastSavedPath
                    if let path = currentPath {
                        Card(title: previewPath != nil ? "Preview" : "Latest song") {
                            AudioPlayerCard(path: path)
                        }
                    }

                    let recent = app.history.entries
                        .filter { $0.kind == .musicGenerate && !$0.savedPaths.isEmpty }
                        .prefix(8)
                    if !recent.isEmpty {
                        Card(title: "Recent songs") {
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
                            "No songs yet",
                            systemImage: "music.note.list",
                            description: Text("Describe a song on the left and hit Generate music.\nSongs are saved to your library folder.")
                        )
                        .padding(.top, 60)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
