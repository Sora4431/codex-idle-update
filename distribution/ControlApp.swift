import AppKit
import Darwin
import ServiceManagement
import SwiftUI

private let agentLabel = "local.codex-idle-update"
private let home = FileManager.default.homeDirectoryForCurrentUser
private let data = home.appendingPathComponent("Library/Application Support/Codex Idle Update")
private let legacyPlist = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

private struct WorkerState: Decodable {
    struct Attempt: Decodable {}
    let status: String?
    let pending: Attempt?
}

@MainActor
private final class Controls: ObservableObject {
    private let agent = SMAppService.agent(plistName: "\(agentLabel).plist")
    @Published var status: SMAppService.Status = .notRegistered
    @Published var worker: String?
    @Published var legacy = false
    @Published var compatible = false
    @Published var error: String?

    func refresh() {
        legacy = FileManager.default.fileExists(atPath: legacyPlist.path)
        status = agent.status
        compatible = Bundle(path: "/Applications/ChatGPT.app")?.bundleIdentifier == "com.openai.codex"
        worker = (try? readState())?.status
    }

    func enable() {
        change {
            guard !legacy, compatible else { return }
            try agent.register()
        }
    }

    func disable() {
        change {
            // A running agent may be terminated by unregister(). Protect update recovery.
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let fd = open(data.appendingPathComponent("run.lock").path, O_CREAT | O_CLOEXEC | O_WRONLY, 0o600)
            guard fd >= 0 else { throw ControlError(message: "更新ジョブの状態を確認できませんでした。") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, try readState()?.pending == nil else {
                throw ControlError(message: "更新ジョブの処理中です。少し待ってから停止してください。")
            }
            try agent.unregister()
        }
    }

    private func change(_ action: () throws -> Void) {
        error = nil
        refresh()
        do { try action() }
        catch { self.error = error.localizedDescription }
        refresh()
    }

    private func readState() throws -> WorkerState? {
        do {
            return try JSONDecoder().decode(WorkerState.self, from: Data(contentsOf: data.appendingPathComponent("state.json")))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }
}

private struct ControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct CodexIdleUpdateApp: App {
    var body: some Scene {
        Window("Codex Idle Update", id: "controls") {
            ControlView()
        }
        .windowResizability(.contentSize)
    }
}

private struct ControlView: View {
    @StateObject private var controls = Controls()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Codex Idle Update", systemImage: "arrow.clockwise")
                .font(.title2.weight(.semibold))
            Text("Codex の更新が準備できたら、作業の合間にアプリを開き直して適用します。")
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(statusText).font(.headline)
                if let worker = controls.worker, controls.legacy || controls.status == .enabled {
                    Text(worker)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if controls.legacy {
                    Text("この Mac では既存の自動更新ジョブが使われています。")
                        .foregroundStyle(.secondary)
                } else if !controls.compatible {
                    Text("「アプリケーション」フォルダに対応する ChatGPT.app をインストールしてください。")
                        .foregroundStyle(.secondary)
                }
                if let error = controls.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            HStack {
                Button("状態を更新") { controls.refresh() }
                Spacer()
                if !controls.legacy {
                    if controls.status == .requiresApproval {
                        Button("システム設定を開く") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    if controls.status == .enabled || controls.status == .requiresApproval {
                        Button("自動更新を停止") { controls.disable() }
                    } else {
                        Button("自動更新を有効にする") { controls.enable() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!controls.compatible || controls.status == .notFound)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { controls.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controls.refresh()
        }
    }

    private var statusText: String {
        if controls.legacy { return "既存のジョブを検出" }
        switch controls.status {
        case .enabled: return "自動更新は有効です"
        case .requiresApproval: return "バックグラウンド実行の許可待ち"
        case .notRegistered: return "自動更新は停止中です"
        case .notFound: return "自動更新サービスが見つかりません"
        @unknown default: return "自動更新の状態を確認できません"
        }
    }
}
