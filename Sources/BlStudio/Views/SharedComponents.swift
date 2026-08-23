import SwiftUI
import AppKit
import AVFoundation

// MARK: - Image thumbnail

struct ThumbImage: View {
    let path: String
    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Run phase footer

struct PhaseFooter: View {
    let phase: GenPhase
    let progressLine: String

    var body: some View {
        Group {
            switch phase {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressLine.isEmpty ? "Working…" : progressLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .done:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Done").font(.callout)
                }
            case .failed(let message):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Text field with suggestion menu (for model ids)

struct SuggestingField: View {
    let title: String
    @Binding var text: String
    var suggestions: [String]
    var placeholder: String = "default"

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
            Menu {
                Button("Use default (empty)") { text = "" }
                Divider()
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { text = s }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("\(title) suggestions")
        }
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}

// MARK: - Card container

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

// MARK: - Reveal / copy helpers

enum FileActions {
    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard let first = urls.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls.count > 1 ? urls : [first])
    }

    static func copyToPasteboard(_ path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - Audio player

/// Compact player for generated music/speech with play/pause and a scrubber.
struct AudioPlayerCard: View {
    let path: String
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $progress, in: 0...max(duration, 0.01)) { editing in
                        if !editing { seek(to: progress) }
                    }
                    HStack {
                        Text(Self.timeString(progress))
                        Spacer()
                        Text(Self.timeString(duration))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                Button { FileActions.open(path) } label: {
                    Label("Open", systemImage: "waveform")
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
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    private func setup() {
        guard player == nil else { return }
        let p = AVPlayer(url: URL(fileURLWithPath: path))
        player = p
        Task {
            guard let item = p.currentItem else { return }
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                duration = max(d.seconds, 0.01)
            }
        }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            progress = time.seconds
            isPlaying = p.timeControlStatus == .playing
        }
    }

    private func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Compact row for a generated audio result in the recent lists.
struct AudioRow: View {
    let title: String
    let subtitle: String
    let path: String
    var onPlay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onPlay) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Preview in player")
            Button { FileActions.reveal([path]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 4)
    }
}
