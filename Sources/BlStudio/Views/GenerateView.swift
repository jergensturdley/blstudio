import SwiftUI

struct GenerateView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var gen = app.generate
        @Bindable var prompts = app.prompts

        HStack(spacing: 0) {
            // MARK: Left (prompt & options)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Prompt") {
                        TextEditor(text: $gen.prompt)
                            .font(.body)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )

                        // Style presets
                        FlowLayout(spacing: 6) {
                            ForEach(PromptLibrary.presets) { preset in
                                let active = gen.activePresets.contains(preset.name)
                                Button {
                                    gen.togglePreset(preset)
                                } label: {
                                    Text(preset.name)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule().fill(active ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
                                        )
                                        .overlay(Capsule().strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !prompts.favorites.isEmpty {
                            Menu {
                                ForEach(prompts.favorites, id: \.self) { fav in
                                    Button(fav.prefix(60).description) { gen.prompt = fav }
                                }
                            } label: {
                                Label("Favorites (\(prompts.favorites.count))", systemImage: "star")
                                    .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }

                        HStack {
                            Button {
                                prompts.toggleFavorite(gen.prompt)
                            } label: {
                                Label(prompts.favorites.contains(gen.prompt.trimmingCharacters(in: .whitespaces))
                                      ? "Unfavorite" : "Save to favorites", systemImage: "star")
                            }
                            .disabled(gen.prompt.trimmingCharacters(in: .whitespaces).isEmpty)

                            Button {
                                Task { await gen.enhancePrompt() }
                            } label: {
                                if gen.enhancing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Enhance with AI", systemImage: "wand.and.stars")
                                }
                            }
                            .disabled(gen.prompt.trimmingCharacters(in: .whitespaces).isEmpty || gen.enhancing)
                            .help("Ask the chat model to rewrite this prompt for better results")

                            Spacer()
                            Button("Clear") {
                                gen.prompt = ""
                                gen.activePresets = []
                            }
                            .disabled(gen.prompt.isEmpty)
                        }
                        .controlSize(.small)

                        if let suggestion = gen.enhanceSuggestion {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("AI suggestion")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(suggestion)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                                HStack {
                                    Button("Use suggestion") {
                                        gen.prompt = suggestion
                                        gen.enhanceSuggestion = nil
                                    }
                                    Button("Dismiss") { gen.enhanceSuggestion = nil }
                                }
                                .controlSize(.small)
                            }
                        }

                        if let err = gen.enhanceError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Card(title: "Options") {
                        LabeledContent("Provider") {
                            Picker("", selection: $gen.provider) {
                                Text("Bailian (bl)").tag(KeyProvider.bailian.rawValue)
                                Text("MiniMax").tag(KeyProvider.minimax.rawValue)
                                Text("Pollinations").tag(KeyProvider.pollinations.rawValue)
                                Text("Google Gemini").tag(KeyProvider.gemini.rawValue)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }

                        if gen.isMiniMax {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MiniMax supports 1–9 images per request and fixed aspect ratios. Seed, negative prompt, and watermark are not available.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !app.miniMaxConfigured {
                                    Text("No MiniMax key yet. Add one in the API Keys tab with provider MiniMax.")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        if gen.isPollinations {
                            Text("Pollinations is free and needs no API key. Seed is supported; negative prompt and watermark are not.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if gen.isGemini {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gemini image generation uses a free Google AI Studio key. Seed, negative prompt, and watermark are not available.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !app.geminiConfigured {
                                    Text("No Gemini key yet. Add a free AI Studio key in the API Keys tab with provider Google Gemini.")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }

                        LabeledContent("Model") {
                            SuggestingField(title: "Model", text: $gen.model,
                                            suggestions: modelSuggestions)
                                .frame(maxWidth: 300)
                        }
                        LabeledContent("Size") {
                            if gen.isMiniMax {
                                Picker("", selection: $gen.size) {
                                    ForEach(ModelCatalog.minimaxAspectRatios, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            } else if gen.isPollinations || gen.isGemini {
                                Picker("", selection: $gen.size) {
                                    ForEach(ModelCatalog.freeAspectRatios, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            } else {
                                HStack {
                                    Picker("", selection: $gen.size) {
                                        ForEach(ModelCatalog.sizes, id: \.self) { Text($0).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    if gen.size == "custom" {
                                        TextField("e.g. 2048*2048", text: $gen.customSize)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 120)
                                    }
                                }
                                .frame(maxWidth: 420)
                            }
                        }
                        LabeledContent("Images") {
                            VStack(alignment: .leading, spacing: 2) {
                                Stepper("\(gen.count)", value: $gen.count, in: countRange)
                                    .fixedSize()
                                if gen.count > 1 {
                                    Text(countCaption)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        LabeledContent("Seed") {
                            HStack {
                                Toggle("", isOn: $gen.seedEnabled).labelsHidden().toggleStyle(.switch)
                                if gen.seedEnabled {
                                    TextField("e.g. 42", text: $gen.seedText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 130)
                                    Text("0–2147483647 · each extra image uses seed+1, seed+2…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Button {
                                    gen.randomizeSeed()
                                } label: {
                                    Image(systemName: "dice")
                                }
                                .buttonStyle(.borderless)
                                .help("Fill with a random seed")
                            }
                        }
                        .disabled(gen.isMiniMax || gen.isGemini)
                        LabeledContent("Negative prompt") {
                            TextField("things to avoid", text: $gen.negativePrompt)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                        }
                        .disabled(!isBailian)

                        HStack(spacing: 8) {
                            Button {
                                prompts.toggleNegativeFavorite(gen.negativePrompt)
                            } label: {
                                Label(prompts.negativeFavorites.contains(gen.negativePrompt.trimmingCharacters(in: .whitespaces))
                                      ? "Unsave negative" : "Save negative", systemImage: "ban")
                            }
                            .disabled(gen.negativePrompt.trimmingCharacters(in: .whitespaces).isEmpty)

                            if !prompts.negativeFavorites.isEmpty {
                                Menu {
                                    ForEach(prompts.negativeFavorites, id: \.self) { neg in
                                        Button(neg.prefix(60).description) { gen.negativePrompt = neg }
                                    }
                                } label: {
                                    Label("Saved (\(prompts.negativeFavorites.count))", systemImage: "ban")
                                        .font(.caption)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }

                            Spacer()

                            Button("Clear") { gen.negativePrompt = "" }
                                .disabled(gen.negativePrompt.isEmpty)
                        }
                        .controlSize(.small)
                        .disabled(!isBailian)

                        if gen.isMiniMax || isBailian {
                            LabeledContent("Prompt extend") {
                                TriStatePicker(value: $gen.promptExtend)
                            }
                        }
                        LabeledContent("Watermark") {
                            TriStatePicker(value: $gen.watermark)
                        }
                        .disabled(!isBailian)
                    }

                    HStack {
                        Button {
                            runningTask = Task { await gen.generate() }
                        } label: {
                            Label("Generate", systemImage: "sparkles")
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!gen.canRun)

                        if gen.phase == .running {
                            Button("Cancel", role: .cancel) {
                                runningTask?.cancel()
                            }
                        }
                    }

                    PhaseFooter(phase: gen.phase, progressLine: gen.progressLine)
                }
                .padding()
            }
            .frame(minWidth: 430, maxWidth: 520)
            .onChange(of: gen.provider) { _, _ in
                if gen.isMiniMax {
                    if !ModelCatalog.minimaxAspectRatios.contains(gen.size) { gen.size = "1:1" }
                    if gen.count > 9 { gen.count = 9 }
                } else if gen.isPollinations || gen.isGemini {
                    if !ModelCatalog.freeAspectRatios.contains(gen.size) { gen.size = "1:1" }
                    if gen.count > 4 { gen.count = 4 }
                } else {
                    if gen.count > 6 { gen.count = 6 }
                }
            }

            Divider()

            // MARK: Right (results)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !gen.lastSavedPaths.isEmpty {
                        Card(title: "Latest result") {
                            ImageGrid(paths: gen.lastSavedPaths)
                        }
                    }

                    let recent = app.history.entries
                        .filter { $0.kind == .imageGenerate && !$0.savedPaths.isEmpty }
                        .prefix(8)
                    if !recent.isEmpty {
                        Card(title: "Recent generations") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                                ForEach(Array(recent)) { entry in
                                    ThumbImage(path: entry.savedPaths[0])
                                        .frame(height: 130)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .onTapGesture {
                                            fullImage = FullImageItem(paths: entry.savedPaths, index: 0, entry: entry)
                                        }
                                }
                            }
                        }
                    }

                    if gen.lastSavedPaths.isEmpty && recent.isEmpty {
                        ContentUnavailableView(
                            "No images yet",
                            systemImage: "photo.stack",
                            description: Text("Write a prompt on the left and hit Generate.\nImages are saved to your library folder.")
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
        .sheet(item: $fullImage) { item in
            FullImageViewer(paths: item.paths, entry: item.entry, index: item.index)
        }
    }

    @State private var selectedEntry: HistoryEntry?
    @State private var fullImage: FullImageItem?
    @State private var runningTask: Task<Void, Never>?

    // Provider-derived helpers
    private var isBailian: Bool { app.generate.provider == KeyProvider.bailian.rawValue }
    private var modelSuggestions: [String] {
        if app.generate.isMiniMax { return ModelCatalog.minimaxImageModels }
        if app.generate.isPollinations { return ModelCatalog.pollinationsModels }
        if app.generate.isGemini { return ModelCatalog.geminiImageModels }
        return ModelCatalog.imageModels
    }
    private var countRange: ClosedRange<Int> {
        if app.generate.isMiniMax { return 1...9 }
        if app.generate.isPollinations || app.generate.isGemini { return 1...4 }
        return 1...6
    }
    private var countCaption: String {
        if app.generate.isMiniMax { return "MiniMax returns \(app.generate.count) images in one request." }
        if app.generate.isPollinations || app.generate.isGemini { return "Runs \(app.generate.count) requests in sequence." }
        return "Runs \(app.generate.count) parallel single-image requests (works with every model)."
    }
}

/// on/off/default tri-state control for optional CLI flags.
struct TriStatePicker: View {
    @Binding var value: Bool?

    var body: some View {
        Picker("", selection: Binding(
            get: { value == nil ? "default" : (value! ? "on" : "off") },
            set: { newValue in
                switch newValue {
                case "on": value = true
                case "off": value = false
                default: value = nil
                }
            }
        )) {
            Text("Default").tag("default")
            Text("On").tag("on")
            Text("Off").tag("off")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
    }
}

/// Clickable image grid with per-image actions. Tapping an image opens the
/// in-app full-size viewer.
struct ImageGrid: View {
    let paths: [String]
    @State private var fullImage: FullImageItem?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                VStack(spacing: 6) {
                    ThumbImage(path: path)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture {
                            fullImage = FullImageItem(paths: paths, index: index, entry: nil)
                        }
                    HStack(spacing: 8) {
                        Button { FileActions.copyToPasteboard(path) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("Copy image")
                        Button { FileActions.reveal([path]) } label: {
                            Image(systemName: "folder")
                        }
                        .help("Reveal in Finder")
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            }
        }
        .sheet(item: $fullImage) { item in
            FullImageViewer(paths: item.paths, entry: item.entry, index: item.index)
        }
    }
}

/// Minimal flow layout for preset chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layoutRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + row.height + (acc > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 400, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var maxWidth: CGFloat = 0
        for row in layoutRows(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            maxWidth = max(maxWidth, row.width)
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? 400
        var rows: [Row] = []
        var current = Row()
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.indices.append(i)
            current.width += (current.indices.count > 1 ? spacing : 0) + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
