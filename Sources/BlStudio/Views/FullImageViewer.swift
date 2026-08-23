import SwiftUI
import AppKit

/// Identifiable payload for presenting the full-screen image viewer.
struct FullImageItem: Identifiable {
    let id = UUID()
    var paths: [String]
    var index: Int
    var entry: HistoryEntry? = nil
}

/// Full-size, zoomable in-app image viewer so you don't need Preview.
struct FullImageViewer: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let paths: [String]
    let entry: HistoryEntry?
    @State var index: Int

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var describing = false
    @State private var description: String?
    @State private var describeError: String?

    private var currentPath: String? {
        paths.indices.contains(index) ? paths[index] : nil
    }

    private var nsImage: NSImage? {
        guard let p = currentPath else { return nil }
        return NSImage(contentsOfFile: p)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 0) {
                // Image area
                Group {
                    if let img = nsImage {
                        ZoomableImage(nsImage: img, zoom: $zoom, offset: $offset)
                    } else {
                        ContentUnavailableView("Could not load image",
                                               systemImage: "photo.badge.exclamationmark")
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                infoBar
            }
            .padding(.top, 36)

            closeButton
        }
        .frame(minWidth: 760, minHeight: 560)
        .onExitCommand { dismiss() }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .padding(14)
    }

    private var infoBar: some View {
        VStack(spacing: 8) {
            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
            }
            if let describeError {
                Text(describeError).font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 14) {
                if paths.count > 1 {
                    HStack(spacing: 6) {
                        Button { step(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(index <= 0)
                        Text("\(index + 1) / \(paths.count)")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Button { step(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(index >= paths.count - 1)
                    }
                    Divider().frame(height: 18)
                }

                // Zoom controls
                HStack(spacing: 6) {
                    Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(zoom <= 1)
                    Text("\(Int(zoom * 100))%")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 46)
                    Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(zoom >= 8)
                    Button { reset() } label: { Image(systemName: "arrow.down.left.and.arrow.up.right") }
                        .help("Fit to window")
                }
                Divider().frame(height: 18)

                if let p = currentPath {
                    Button { FileActions.open(p) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                        .help("Open in Preview")
                    Button { FileActions.reveal([p]) } label: { Label("Reveal", systemImage: "folder") }
                    Button { FileActions.copyToPasteboard(p) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }

                if let entry, entry.kind == .imageGenerate || entry.kind == .imageEdit {
                    Divider().frame(height: 18)
                    Button {
                        sendToEdit()
                    } label: { Label("Edit", systemImage: "wand.and.stars") }
                        .help("Use as edit source")

                    Button {
                        Task { await describeImage() }
                    } label: {
                        if describing { ProgressView().controlSize(.small) }
                        else { Label("Describe", systemImage: "eye") }
                    }
                    .disabled(describing)
                }
            }
            .controlSize(.small)
            .tint(.white)

            if let entry {
                Text(entry.prompt)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
                    .frame(maxWidth: 560)
            } else if let p = currentPath {
                Text("\(URL(fileURLWithPath: p).lastPathComponent)\(sizeSuffix)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.35))
    }

    private var sizeSuffix: String {
        guard let img = nsImage, let rep = img.representations.first,
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return "" }
        return "  ·  \(rep.pixelsWide)×\(rep.pixelsHigh)"
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard paths.indices.contains(next) else { return }
        index = next
        reset()
        description = nil
        describeError = nil
    }

    private func setZoom(_ z: CGFloat) {
        zoom = min(max(z, 1), 8)
        if zoom == 1 { offset = .zero }
    }

    private func reset() {
        withAnimation(.easeInOut(duration: 0.15)) {
            zoom = 1
            offset = .zero
        }
    }

    private func sendToEdit() {
        guard let entry else { return }
        let urls = entry.savedPaths.map { URL(fileURLWithPath: $0) }
        app.edit.sources = urls
        app.edit.phase = .idle
        app.edit.lastSavedPaths = []
        dismiss()
    }

    private func describeImage() async {
        guard let path = currentPath else { return }
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

/// A zoomable, pannable image. Zoom 1× = fit to window.
struct ZoomableImage: View {
    let nsImage: NSImage
    @Binding var zoom: CGFloat
    @Binding var offset: CGSize

    @GestureState private var magnifyBy: CGFloat = 1
    @GestureState private var dragBy: CGSize = .zero

    private var liveZoom: CGFloat { zoom * magnifyBy }
    private var liveOffset: CGSize {
        CGSize(width: offset.width + dragBy.width, height: offset.height + dragBy.height)
    }

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(liveZoom)
                .offset(liveOffset)
                .contentShape(Rectangle())
                .gesture(magnify)
                .simultaneousGesture(zoom > 1 ? drag : nil)
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if zoom > 1 { zoom = 1; offset = .zero } else { zoom = 2 }
                    }
                }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($magnifyBy) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 1), 8)
                if zoom == 1 { offset = .zero }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .updating($dragBy) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }
}
