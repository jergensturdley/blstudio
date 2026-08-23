import SwiftUI
import AppKit

struct GalleryView: View {
    @Environment(AppState.self) private var app
    @State private var searchText = ""
    @State private var kindFilter: WorkKind? = nil
    @State private var selectedEntry: HistoryEntry?
    @State private var fullImage: FullImageItem?

    private var filtered: [HistoryEntry] {
        app.history.entries.filter { entry in
            if let kindFilter, entry.kind != kindFilter { return false }
            if !searchText.isEmpty,
               !entry.prompt.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search prompts…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)

                Picker("Kind", selection: $kindFilter) {
                    Text("All").tag(WorkKind?.none)
                    Text("Generated").tag(WorkKind?.some(.imageGenerate))
                    Text("Edited").tag(WorkKind?.some(.imageEdit))
                    Text("Video").tag(WorkKind?.some(.videoGenerate))
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                Text("\(filtered.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.bar)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    "Gallery is empty",
                    systemImage: "rectangle.grid.2x2",
                    description: Text("Generated and edited images will appear here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { entry in
                            GalleryCell(entry: entry)
                                .onTapGesture {
                                    if entry.kind == .videoGenerate || entry.savedPaths.isEmpty {
                                        selectedEntry = entry
                                    } else {
                                        fullImage = FullImageItem(paths: entry.savedPaths, index: 0, entry: entry)
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $selectedEntry) { entry in
            GalleryDetailSheet(entry: entry)
        }
        .sheet(item: $fullImage) { item in
            FullImageViewer(paths: item.paths, entry: item.entry, index: item.index)
        }
    }
}

struct GalleryCell: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let path = entry.savedPaths.first {
                    if entry.kind == .videoGenerate {
                        VideoCellPreview(path: path)
                            .frame(height: 170)
                            .frame(maxWidth: .infinity)
                    } else {
                        ThumbImage(path: path)
                            .frame(height: 170)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: entry.ok ? "doc.text" : "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 170)
                }
                Text(entry.kind == .imageEdit ? "edit" : (entry.kind == .videoGenerate ? "video" : "gen"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(entry.prompt)
                .font(.caption)
                .lineLimit(2)
            Text(Fmt.shortDate.string(from: entry.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct GalleryDetailSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let entry: HistoryEntry

    @State private var description: String?
    @State private var describing = false
    @State private var describeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry.kind.rawValue.capitalized)
                    .font(.headline)
                Text(Fmt.shortDate.string(from: entry.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
            }

            HStack(alignment: .top, spacing: 16) {
                if entry.kind == .videoGenerate, let path = entry.savedPaths.first {
                    VideoPlayerCard(path: path)
                        .frame(maxWidth: 420)
                } else if let path = entry.savedPaths.first,
                          let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.prompt)
                        .textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        if let model = entry.model {
                            GridRow { metaLabel("model"); Text(model).textSelection(.enabled) }
                        }
                        GridRow { metaLabel("key"); Text(entry.keyLabel) }
                        GridRow { metaLabel("took"); Text("\(Double(entry.durationMs) / 1000, specifier: "%.1f")s") }
                        if let task = entry.taskId {
                            GridRow { metaLabel("task"); Text(task).textSelection(.enabled).lineLimit(1) }
                        }
                        if !entry.ok, let detail = entry.detail {
                            GridRow {
                                metaLabel("error")
                                Text(detail).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)

                    if !entry.savedPaths.isEmpty {
                        HStack(spacing: 8) {
                            Button {
                                FileActions.open(entry.savedPaths[0])
                            } label: { Label("Open", systemImage: "arrow.up.right.square") }

                            Button {
                                FileActions.copyToPasteboard(entry.savedPaths[0])
                            } label: { Label("Copy", systemImage: "doc.on.doc") }

                            Button {
                                FileActions.reveal(entry.savedPaths)
                            } label: { Label("Reveal", systemImage: "folder") }
                        }
                        .controlSize(.small)
                    }

                    if entry.kind == .imageGenerate || entry.kind == .imageEdit {
                        Divider()
                        HStack {
                            Button {
                                sendToEdit()
                            } label: {
                                Label("Use as edit source", systemImage: "wand.and.stars")
                            }
                            .disabled(entry.savedPaths.isEmpty)

                            Button {
                                Task { await describeImage() }
                            } label: {
                                Label("Describe", systemImage: "eye")
                            }
                            .disabled(entry.savedPaths.isEmpty || describing)
                        }
                        .controlSize(.small)

                        if describing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Describing…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let description {
                            Text(description)
                                .font(.caption)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                        }
                        if let describeError {
                            Text(describeError).font(.caption).foregroundStyle(.red)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 480)
    }

    private func metaLabel(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
    }

    private func sendToEdit() {
        let urls = entry.savedPaths.map { URL(fileURLWithPath: $0) }
        app.edit.sources = urls
        app.edit.phase = .idle
        app.edit.lastSavedPaths = []
        dismiss()
    }

    private func describeImage() async {
        guard let path = entry.savedPaths.first else { return }
        describing = true
        describeError = nil
        description = nil
        defer { describing = false }
        do {
            let result = try await app.client.visionDescribe(
                imagePath: path, prompt: nil, model: nil, apiKey: app.activeSecret)
            description = result
            app.recordUsage(kind: .vision, model: nil, durationMs: 0, ok: true)
        } catch {
            describeError = error.localizedDescription
        }
    }
}
