import SwiftUI
import AppKit

@main
struct BlStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    init() {
        // Headless smoke tests: `BlStudio --selftest`
        if CommandLine.arguments.contains("--selftest") {
            let sem = DispatchSemaphore(value: 0)
            let box = ExitCodeBox()
            Task.detached {
                box.code = await SelfTest.run()
                sem.signal()
            }
            sem.wait()
            exit(box.code)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 1000, minHeight: 640)
                .task { await appState.refreshStatus() }
        }
    }
}

/// Small mutable box to carry the self-test exit code across a concurrency domain.
final class ExitCodeBox: @unchecked Sendable {
    var code: Int32 = 1
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make the SwiftUI process behave like a regular .app even when launched
        // from `swift run` (activation policy is inherited from Info.plist in bundles).
        if Bundle.main.bundlePath.hasSuffix(".app") == false {
            NSApp.setActivationPolicy(.regular)
        }

        // Headless view smoke test: render every feature view offscreen and exit.
        if ProcessInfo.processInfo.arguments.contains("--viewprobe") {
            exit(SelfTest.runViewProbe())
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case generate = "Generate"
    case edit = "Edit"
    case chat = "Chat"
    case gallery = "Gallery"
    case quota = "Quota"
    case keys = "API Keys"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .generate: return "photo.badge.plus"
        case .edit: return "wand.and.stars"
        case .chat: return "bubble.left.and.bubble.right"
        case .gallery: return "rectangle.grid.2x2"
        case .quota: return "gauge.with.dots.needle.67percent"
        case .keys: return "key.horizontal"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var selection: SidebarSection? = .generate

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("BlStudio")
            .safeAreaInset(edge: .bottom) {
                statusFooter
            }
        } detail: {
            switch selection ?? .generate {
            case .generate: GenerateView()
            case .edit: EditView()
            case .chat: ChatView()
            case .gallery: GalleryView()
            case .quota: QuotaView()
            case .keys: KeysView()
            case .settings: SettingsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                KeyPicker()
            }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let auth = app.authStatus {
                HStack(spacing: 6) {
                    Circle()
                        .fill((auth.authenticated ?? false) ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text((auth.authenticated ?? false)
                         ? "bl authenticated · profile \(auth.config ?? "?")"
                         : "bl not authenticated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let masked = auth.api_key?.masked {
                    Text("key \(masked)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(.gray).frame(width: 8, height: 8)
                    Text("checking bl status…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let v = app.cliVersion {
                Text(v).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }
}

/// Global API-key selector shown in the toolbar.
struct KeyPicker: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var keys = app.keysStore
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.secondary)
            Picker("API key", selection: $keys.activeKeyId) {
                Text("CLI default profile").tag(UUID?.none)
                ForEach(keys.keys) { key in
                    Text("\(key.label) (\(key.masked))").tag(UUID?.some(key.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 300)
        }
    }
}
