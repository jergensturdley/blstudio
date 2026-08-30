import SwiftUI
import AppKit
import Security

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

        // Headless endpoint smoke test against the stored keys:
        // `BlStudio --smoketest` (free checks) or `BlStudio --smoketest full`.
        // Extra words limit the run to matching providers, e.g.
        // `BlStudio --smoketest full huggingface`.
        let smArgs = ProcessInfo.processInfo.arguments
        if smArgs.contains("--smoketest") {
            let full = smArgs.contains("full")
            let skip: Set<String> = ["--smoketest", "full"]
            let only = smArgs.dropFirst().filter { !skip.contains($0) && !$0.hasPrefix("-") }
            Task { @MainActor in
                exit(await SmokeTest.run(full: full, only: Array(only)))
            }
            return
        }

        // Headless keychain diagnostic (maintenance):
        // `BlStudio --keydiag <keychain-account-uuid> [dpk]` prints the raw
        // OSStatus; `dpk` probes the modern data-protection keychain instead.
        if let idx = smArgs.firstIndex(of: "--keydiag"), smArgs.count > idx + 1 {
            let account = smArgs[idx + 1]
            let dpk = smArgs.count > idx + 2 && smArgs[idx + 2] == "dpk"
            Task { @MainActor in
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "BlStudio",
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                if dpk { query[kSecUseDataProtectionKeychain as String] = true }
                let started = Date()
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let len = (item as? Data)?.count ?? 0
                print("status=\(status) elapsed=\(ms)ms secretLen=\(len)")
                exit(status == errSecSuccess ? 0 : 1)
            }
            return
        }

        // Headless DPK experiment (maintenance):
        // `BlStudio --keydpk-set <account> <secret>` stores in the
        // data-protection keychain; read back with `--keydiag <account> dpk`.
        if let idx = smArgs.firstIndex(of: "--keydpk-set"), smArgs.count > idx + 2 {
            let account = smArgs[idx + 1]
            let secret = smArgs[idx + 2]
            Task { @MainActor in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "BlStudio",
                    kSecAttrAccount as String: account,
                ]
                var attrs = query
                attrs[kSecValueData as String] = Data(secret.utf8)
                attrs[kSecUseDataProtectionKeychain as String] = true
                attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemDelete(attrs as CFDictionary)
                let status = SecItemAdd(attrs as CFDictionary, nil)
                print("add status=\(status)")
                exit(status == errSecSuccess ? 0 : 1)
            }
            return
        }

        // Headless key import (maintenance):
        // `BlStudio --set-key <provider> <secret> [label] [accountId]`
        if let idx = smArgs.firstIndex(of: "--set-key"), smArgs.count > idx + 2 {
            let providerRaw = smArgs[idx + 1]
            let secret = smArgs[idx + 2]
            let label = smArgs.count > idx + 3 ? smArgs[idx + 3] : "main"
            let accountId: String? = smArgs.count > idx + 4 ? smArgs[idx + 4] : nil
            Task { @MainActor in
                let app = AppState()
                guard let provider = KeyProvider(rawValue: providerRaw) else {
                    print("unknown provider: \(providerRaw)")
                    exit(2)
                }
                do {
                    let meta = try app.keysStore.add(label: label, secret: secret,
                                                     provider: provider, accountId: accountId)
                    print("stored \(providerRaw) key [\(meta.label)] id=\(meta.id.uuidString)")
                    exit(0)
                } catch {
                    print("failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case generate = "Generate"
    case edit = "Edit"
    case video = "Video"
    case music = "Music"
    case speech = "Speech"
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
        case .video: return "film"
        case .music: return "music.note"
        case .speech: return "waveform"
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
            case .video: VideoView()
            case .music: MusicView()
            case .speech: SpeechView()
            case .chat: ChatView()
            case .gallery: GalleryView()
            case .quota: QuotaView()
            case .keys: KeysView()
            case .settings: SettingsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("BlStudio").font(.headline)
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
