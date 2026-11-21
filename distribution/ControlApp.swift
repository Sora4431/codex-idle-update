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
            guard fd >= 0 else { throw ControlError(message: "Could not check the update service.") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, try readState()?.pending == nil else {
                throw ControlError(message: "An update check or restart is in progress. Wait a moment before disabling auto updates.")
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
            Text("Applies prepared ChatGPT updates by reopening the app when Codex is idle.")
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
                    Text("The existing background job handles auto updates on this Mac.")
                        .foregroundStyle(.secondary)
                } else if !controls.compatible {
                    Text("Install a compatible ChatGPT.app in the Applications folder.")
                        .foregroundStyle(.secondary)
                }
                if let error = controls.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            HStack {
                Button("Refresh Status") { controls.refresh() }
                Spacer()
                if !controls.legacy {
                    if controls.status == .requiresApproval {
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    if controls.status == .enabled || controls.status == .requiresApproval {
                        Button("Disable Auto Updates") { controls.disable() }
                    } else {
                        Button("Enable Auto Updates") { controls.enable() }
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
        if controls.legacy { return "Existing background job detected" }
        switch controls.status {
        case .enabled: return "Auto updates are enabled"
        case .requiresApproval: return "Waiting for permission to run in the background"
        case .notRegistered: return "Auto updates are disabled"
        case .notFound: return "Update service unavailable"
        @unknown default: return "Update service status unknown"
        }
    }
}
