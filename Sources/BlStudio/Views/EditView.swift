import SwiftUI
import UniformTypeIdentifiers

struct EditView: View {
    @Environment(AppState.self) private var app
    @State private var showImporter = false
    @State private var selectedEntry: HistoryEntry?
    @State private var runningTask: Task<Void, Never>?

    var body: some View {
        @Bindable var edit = app.edit

        HStack(spacing: 0) {
            // MARK: Left (sources, prompt, options)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Source images") {
                        if edit.sources.isEmpty {
                            dropZone
                        } else {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(edit.sources, id: \.self) { url in
                                        ZStack(alignment: .topTrailing) {
                                            ThumbImage(path: url.path)
                                                .frame(width: 90, height: 90)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                            Button {
                                                edit.removeSource(url)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.white, .black.opacity(0.6))
                                            }
                                            .buttonStyle(.plain)
                                            .padding(2)
                                        }
                                    }
                                }
                            }
                            HStack {
                                Button("Add images…") { showImporter = true }
                                Button("Clear") {
                                    for u in edit.sources { u.stopAccessingSecurityScopedResource() }
                                    edit.sources = []
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    Card(title: "Edit instruction") {
                        TextEditor(text: $edit.prompt)
                            .font(.body)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))

                        LabeledContent("Model") {
                            SuggestingField(title: "Model", text: $edit.model,
                                            suggestions: ModelCatalog.editModels)
                                .frame(maxWidth: 300)
                        }
                        LabeledContent("Function") {
                            SuggestingField(title: "Function", text: $edit.editFunction,
                                            suggestions: ModelCatalog.editFunctions,
                                            placeholder: "description_edit")
                                .frame(maxWidth: 300)
                        }
                        LabeledContent("Size") {
                            TextField("e.g. 1:1 or 2048*2048 (optional)", text: $edit.size)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                        }
                        LabeledContent("Images") {
                            VStack(alignment: .leading, spacing: 2) {
                                Stepper("\(edit.count)", value: $edit.count, in: 1...6)
                                    .fixedSize()
                                if edit.count > 1 {
                                    Text("Runs \(edit.count) parallel single-image requests.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        LabeledContent("Seed") {
                            HStack {
                                Toggle("", isOn: $edit.seedEnabled).labelsHidden().toggleStyle(.switch)
                                if edit.seedEnabled {
                                    TextField("e.g. 42", text: $edit.seedText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 130)
                                    Text("0–2147483647")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    edit.randomizeSeed()
                                } label: {
                                    Image(systemName: "dice")
                                }
                                .buttonStyle(.borderless)
                                .help("Fill with a random seed")
                            }
                        }
                        LabeledContent("Negative prompt") {
                            TextField("things to avoid", text: $edit.negativePrompt)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                        }

                        HStack(spacing: 8) {
                            Button {
                                app.prompts.toggleNegativeFavorite(edit.negativePrompt)
                            } label: {
                                Label(app.prompts.negativeFavorites.contains(edit.negativePrompt.trimmingCharacters(in: .whitespaces))
                                      ? "Unsave negative" : "Save negative", systemImage: "ban")
                            }
                            .disabled(edit.negativePrompt.trimmingCharacters(in: .whitespaces).isEmpty)

                            if !app.prompts.negativeFavorites.isEmpty {
                                Menu {
                                    ForEach(app.prompts.negativeFavorites, id: \.self) { neg in
                                        Button(neg.prefix(60).description) { edit.negativePrompt = neg }
                                    }
                                } label: {
                                    Label("Saved (\(app.prompts.negativeFavorites.count))", systemImage: "ban")
                                        .font(.caption)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }

                            Spacer()

                            Button("Clear") { edit.negativePrompt = "" }
                                .disabled(edit.negativePrompt.isEmpty)
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Button {
                            runningTask = Task { await edit.generate() }
                        } label: {
                            Label("Edit image", systemImage: "wand.and.stars")
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!edit.canRun)

                        if edit.phase == .running {
                            Button("Cancel", role: .cancel) {
                                runningTask?.cancel()
                            }
                        }
                    }

                    PhaseFooter(phase: edit.phase, progressLine: edit.progressLine)
                }
                .padding()
            }
            .frame(minWidth: 430, maxWidth: 520)

            Divider()

            // MARK: Right (results)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !edit.lastSavedPaths.isEmpty {
                        Card(title: "Latest result") {
                            ImageGrid(paths: edit.lastSavedPaths)
                        }
                    }

                    let recent = app.history.entries
                        .filter { $0.kind == .imageEdit && !$0.savedPaths.isEmpty }
                        .prefix(8)
                    if !recent.isEmpty {
                        Card(title: "Recent edits") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                                ForEach(Array(recent)) { entry in
                                    ThumbImage(path: entry.savedPaths[0])
                                        .frame(height: 130)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .onTapGesture { selectedEntry = entry }
                                }
                            }
                        }
                    }

                    if edit.lastSavedPaths.isEmpty && recent.isEmpty {
                        ContentUnavailableView(
                            "No edits yet",
                            systemImage: "wand.and.stars",
                            description: Text("Drop a source image, describe the edit you want, and run.")
                        )
                        .padding(.top, 60)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                edit.addSources(urls)
            }
        }
        .sheet(item: $selectedEntry) { entry in
            GalleryDetailSheet(entry: entry)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Drop images here, or")
                .foregroundStyle(.secondary)
            Button("Choose files…") { showImporter = true }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(.quaternary)
        )
        .dropDestination(for: URL.self) { urls, _ in
            app.edit.addSources(urls.filter { isImageFile($0) })
            return true
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
