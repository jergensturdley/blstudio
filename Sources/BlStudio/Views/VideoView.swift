import SwiftUI
import AVKit

struct VideoView: View {
    @Environment(AppState.self) private var app

    @State private var runningTask: Task<Void, Never>?
    @State private var showFileImporter = false
    @State private var selectedEntry: HistoryEntry?

    var body: some View {
        @Bindable var vid = app.video

        HStack(spacing: 0) {
            // MARK: Left (prompt & options)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Prompt") {
                        TextEditor(text: $vid.prompt)
                            .font(.body)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                        HStack {
                            Spacer()
                            Button("Clear") { vid.prompt = "" }
                                .disabled(vid.prompt.isEmpty)
                        }
                        .controlSize(.small)
                    }

                    Card(title: "Options") {
                        LabeledContent("Provider") {
                            Picker("", selection: $vid.provider) {
                                ForEach(enabledVideoProviders, id: \.rawValue) { p in
                                    Text(p.label).tag(p.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }

                        LabeledContent("Mode") {
                            Picker("", selection: $vid.mode) {
                                Text("Text to video").tag("t2v")
                                Text("Image to video").tag("i2v")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }

                        if vid.isMiniMax {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MiniMax video runs through the mmx CLI. MiniMax-H3 is the newest model (2K output, 4–15 s clips); rendering takes a few minutes.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !app.mmx.isAvailable() {
                                    Text("mmx CLI not found. Install it with `npm i -g mmx-cli`, or set its path in Settings.")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                                if !app.miniMaxConfigured {
                                    Text("No MiniMax key yet. Add one in the API Keys tab with provider MiniMax.")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }

                        LabeledContent("Model") {
                            Picker("", selection: $vid.model) {
                                ForEach(modelOptions(vid), id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }

                        if vid.mode == "i2v" {
                            if vid.isMiniMax {
                                LabeledContent("First frame") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Button {
                                            showFileImporter = true
                                        } label: {
                                            Label(vid.i2vFileURL?.lastPathComponent ?? "Choose image…",
                                                  systemImage: "photo")
                                        }
                                        if let f = vid.i2vFileURL {
                                            ThumbImage(path: f.path)
                                                .frame(height: 80)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                    }
                                    .frame(maxWidth: 300, alignment: .leading)
                                }
                            } else {
                                LabeledContent("Source image URL") {
                                    TextField("https://…/image.png", text: $vid.imageURL)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 300)
                                }
                                Text("Bailian image-to-video needs a publicly reachable image URL.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !vid.isMiniMax {
                            LabeledContent("Resolution") {
                                Picker("", selection: $vid.resolution) {
                                    ForEach(ModelCatalog.videoResolutionsBailian, id: \.self) {
                                        Text($0).tag($0)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }
                        } else if vid.isH3 {
                            LabeledContent("Resolution") {
                                Text("2K (fixed)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !vid.isMiniMax {
                            LabeledContent("Aspect ratio") {
                                Picker("", selection: $vid.ratio) {
                                    ForEach(ModelCatalog.videoRatiosBailian, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }
                        } else if vid.isH3 {
                            LabeledContent("Aspect ratio") {
                                Picker("", selection: $vid.ratio) {
                                    ForEach(ModelCatalog.h3Ratios, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }
                        }

                        if !vid.isMiniMax {
                            LabeledContent("Duration") {
                                Picker("", selection: $vid.duration) {
                                    ForEach(ModelCatalog.videoDurationsBailian, id: \.self) {
                                        Text("\($0)s").tag($0)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }
                        } else if vid.isH3 {
                            LabeledContent("Duration") {
                                Stepper(value: $vid.duration, in: ModelCatalog.h3DurationRange) {
                                    Text("\(vid.duration)s").monospacedDigit()
                                }
                                .fixedSize()
                            }
                        } else {
                            LabeledContent("Duration") {
                                Text("set by model")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !vid.isMiniMax {
                            LabeledContent("Seed") {
                                HStack {
                                    Toggle("", isOn: $vid.seedEnabled).labelsHidden().toggleStyle(.switch)
                                    if vid.seedEnabled {
                                        TextField("e.g. 42", text: $vid.seedText)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 130)
                                    }
                                    Button {
                                        vid.randomizeSeed()
                                    } label: {
                                        Image(systemName: "dice")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Fill with a random seed")
                                }
                            }
                            LabeledContent("Prompt extend") {
                                TriStatePicker(value: $vid.promptExtend)
                            }
                            LabeledContent("Watermark") {
                                TriStatePicker(value: $vid.watermark)
                            }
                        }
                    }

                    HStack {
                        Button {
                            runningTask = Task { await vid.generate() }
                        } label: {
                            Label("Generate video", systemImage: "film")
                                .frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!vid.canRun)

                        if vid.phase == .running {
                            Button("Cancel", role: .cancel) {
                                runningTask?.cancel()
                            }
                        }
                    }

                    PhaseFooter(phase: vid.phase, progressLine: vid.progressLine)
                }
                .padding()
            }
            .frame(minWidth: 430, maxWidth: 520)
            .onAppear { ensureValidVideoProvider() }
            .onChange(of: app.settingsStore.settings.disabledProviders) { _, _ in
                ensureValidVideoProvider()
            }
            .onChange(of: vid.provider) { _, _ in normalize(vid) }
            .onChange(of: vid.mode) { _, _ in normalize(vid) }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.png, .jpeg, .webP],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let first = urls.first {
                    vid.i2vFileURL = first
                }
            }

            Divider()

            // MARK: Right (results)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let path = vid.lastSavedPath {
                        Card(title: "Latest video") {
                            VideoPlayerCard(path: path)
                        }
                    }

                    let recent = app.history.entries
                        .filter { $0.kind == .videoGenerate && !$0.savedPaths.isEmpty }
                        .prefix(6)
                    if !recent.isEmpty {
                        Card(title: "Recent videos") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                                ForEach(Array(recent)) { entry in
                                    VideoCellPreview(path: entry.savedPaths[0])
                                        .frame(height: 120)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .onTapGesture { selectedEntry = entry }
                                }
                            }
                        }
                    }

                    if vid.lastSavedPath == nil && recent.isEmpty {
                        ContentUnavailableView(
                            "No videos yet",
                            systemImage: "film.stack",
                            description: Text("Write a prompt on the left and hit Generate video.\nVideos are saved to your library folder.")
                        )
                        .padding(.top, 60)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $selectedEntry) { entry in
            GalleryDetailSheet(entry: entry)
        }
    }

    private func modelOptions(_ vid: VideoModel) -> [String] {
        if vid.isMiniMax {
            return vid.mode == "i2v" ? ModelCatalog.videoI2VModelsMiniMax
                                     : ModelCatalog.videoT2VModelsMiniMax
        }
        return vid.mode == "i2v" ? ModelCatalog.videoI2VModelsBailian
                                 : ModelCatalog.videoT2VModelsBailian
    }

    /// Resets provider/mode-dependent fields to sane defaults.
    private func normalize(_ vid: VideoModel) {
        let options = modelOptions(vid)
        vid.model = options.first ?? ""
        if vid.isMiniMax {
            vid.resolution = "768P"
            vid.duration = 6
        } else {
            vid.resolution = "1080P"
            vid.ratio = "16:9"
            vid.duration = 5
        }
    }

    private var enabledVideoProviders: [KeyProvider] {
        KeyProvider.videoProviders.filter { app.isProviderEnabled($0) }
    }

    private func ensureValidVideoProvider() {
        let enabled = enabledVideoProviders
        guard !enabled.isEmpty else { return }
        if !enabled.contains(where: { $0.rawValue == app.video.provider }) {
            app.video.provider = enabled[0].rawValue
            normalize(app.video)
        }
    }
}

/// Video playback for a local file, with open/reveal actions.
struct VideoPlayerCard: View {
    let path: String
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "video.slash").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button { FileActions.open(path) } label: {
                    Label("Open", systemImage: "play.rectangle")
                }
                Button { FileActions.reveal([path]) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Spacer()
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .controlSize(.small)
        }
        .onAppear {
            if player == nil {
                player = AVPlayer(url: URL(fileURLWithPath: path))
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

/// Lightweight thumbnail for a video entry in grids.
struct VideoCellPreview: View {
    let path: String

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "film")
                .font(.title)
                .foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottomLeading) {
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(6)
                .lineLimit(1)
        }
    }
}
