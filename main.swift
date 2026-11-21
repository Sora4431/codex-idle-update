import AppKit
import Darwin
import Foundation
import SQLite3

struct CheckError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AppIdentity: Codable, Equatable {
    let pid: pid_t
    let launched: TimeInterval
}

struct Idle: Codable {
    let app: AppIdentity
    let target: Int
    let since: TimeInterval
    var last: TimeInterval
}

struct Attempt: Codable {
    let app: AppIdentity
    let target: Int
    let requested: TimeInterval
}

struct State: Codable {
    var idle: Idle?
    var pending: Attempt?
    var lastAttempt: Attempt?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case idle, pending, status
        case lastAttempt = "last_attempt"
    }
}

private final class CommandOutput: @unchecked Sendable {
    // Each buffer has one writer, and the caller reads both after the group finishes.
    var stdout = Data()
    var stderr = Data()
}

private func command(
    _ executable: String, _ arguments: [String], allowed: Set<Int32> = [0]
) throws -> String {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let output = CommandOutput()
    let group = DispatchGroup()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    group.enter()
    process.terminationHandler = { _ in group.leave() }
    try process.run()
    DispatchQueue.global().async(group: group) {
        output.stdout = stdout.fileHandleForReading.readDataToEndOfFile()
    }
    DispatchQueue.global().async(group: group) {
        output.stderr = stderr.fileHandleForReading.readDataToEndOfFile()
    }
    guard group.wait(timeout: .now() + 12) == .success else {
        if process.isRunning { process.terminate() }
        throw CheckError("\(executable) timed out")
    }
    guard allowed.contains(process.terminationStatus), output.stderr.isEmpty,
          let result = String(data: output.stdout, encoding: .utf8) else {
        throw CheckError("\(executable) exited with status \(process.terminationStatus) or reported a diagnostic")
    }
    return result
}

private final class Database {
    let handle: OpaquePointer
    let name: String

    init(_ path: URL) throws {
        name = path.lastPathComponent
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection else {
            sqlite3_close(connection)
            throw CheckError("could not open \(name) read-only")
        }
        guard sqlite3_busy_timeout(connection, 1_000) == SQLITE_OK else {
            sqlite3_close(connection)
            throw CheckError("could not set the busy timeout for \(name)")
        }
        handle = connection
    }

    deinit { sqlite3_close(handle) }

    func first(_ sql: String, argument: String? = nil) throws -> [String?]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        if let argument {
            let copyText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, argument, -1, copyText) == SQLITE_OK else {
                throw failure()
            }
        }
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            return (0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
        default:
            throw failure()
        }
    }

    private func failure() -> CheckError {
        CheckError("\(name): \(String(cString: sqlite3_errmsg(handle)))")
    }
}

@MainActor
struct IdleUpdater {
    static let idleSeconds: TimeInterval = 600
    static let maxPollGap: TimeInterval = 480
    static let quitTimeout: TimeInterval = 120
    static let retryDelay: TimeInterval = 3_600

    let app: URL
    let bundleID: String
    let profile: URL
    let codex: URL
    let staged: URL
    let data: URL

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        app: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app"),
        bundleID: String = "com.openai.codex"
    ) {
        self.app = app
        self.bundleID = bundleID
        profile = home.appendingPathComponent("Library/Application Support/Codex")
        codex = home.appendingPathComponent(".codex")
        staged = home.appendingPathComponent(
            "Library/Caches/\(bundleID)/org.sparkle-project.Sparkle/Installation"
        )
        data = home.appendingPathComponent("Library/Application Support/Codex Idle Update")
    }

    private var desktopDB: URL { codex.appendingPathComponent("sqlite/codex.db") }
    private var historyDB: URL { codex.appendingPathComponent("thread_history_1.sqlite") }
    private var queueDB: URL { codex.appendingPathComponent("queue_1.sqlite") }
    private var stateFile: URL { data.appendingPathComponent("state.json") }
    private var now: TimeInterval { Date().timeIntervalSince1970 }

    func desktop() throws -> (app: NSRunningApplication, identity: AppIdentity)? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            !$0.isTerminated && $0.bundleURL?.path == app.path
        }
        guard apps.count <= 1 else { throw CheckError("multiple desktop instances") }
        guard let running = apps.first else { return nil }
        guard let launched = running.launchDate else { throw CheckError("missing desktop launch date") }
        return (running, AppIdentity(pid: running.processIdentifier, launched: launched.timeIntervalSince1970))
    }

    func quit(_ identity: AppIdentity) throws -> String {
        guard let running = try desktop(), running.identity == identity else { return "changed" }
        return running.app.terminate() ? "requested" : "declined"
    }

    func build(_ bundle: URL) throws -> Int {
        let bytes = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        guard let values = info as? [String: Any], values["CFBundleIdentifier"] as? String == bundleID,
              let version = values["CFBundleVersion"],
              let number = Int(String(describing: version)) else {
            throw CheckError("unexpected desktop bundle metadata")
        }
        return number
    }

    private func children(_ path: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: path, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ).filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    error.code == NSFileReadNoSuchFileError {
            return []
        }
    }

    private func installerRunning() throws -> Bool {
        let helper = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate")
        return try command("/bin/ps", ["-axo", "comm="]).split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == helper.path
        }
    }

    func stagedBuild(_ installed: Int) throws -> Int? {
        var newer: Set<Int> = []
        for installation in try children(staged) {
            for directory in try children(installation) {
                let bundle = directory.appendingPathComponent(app.lastPathComponent)
                guard FileManager.default.fileExists(atPath: bundle.path) else { continue }
                let candidate = try build(bundle)
                if candidate > installed { newer.insert(candidate) }
            }
        }
        guard !newer.isEmpty, try installerRunning() else { return nil }
        guard newer.count == 1 else { throw CheckError("multiple staged update builds") }
        return newer.first
    }

    func writerFiles() throws -> Set<String> {
        let directory = codex.appendingPathComponent("thread-writer-locks").resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw CheckError("thread writer directory is missing") }
        // lsof 4.91 also exits 1 when some directory entries are not open.
        let output = try command("/usr/sbin/lsof", ["-nP", "-Fn", "+D", directory.path], allowed: [0, 1])
        var writers: Set<String> = []
        for line in output.split(separator: "\n") where line.first == "n" {
            let path = URL(fileURLWithPath: String(line.dropFirst())).resolvingSymlinksInPath()
            if path.path == directory.appendingPathComponent(".coordination.lock").path { continue }
            let id = path.deletingPathExtension().lastPathComponent
            guard path.deletingLastPathComponent().path == directory.path, path.pathExtension == "lock",
                  UUID(uuidString: id)?.uuidString.lowercased() == id else {
                throw CheckError("unrecognized thread writer file")
            }
            writers.insert(id)
        }
        return writers
    }

    private func verifyDatabases(_ identity: AppIdentity) throws {
        let pid = String(identity.pid)
        let server = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let children = try command("/bin/ps", ["-axo", "ppid=,pid=,comm="])
            .split(separator: "\n").compactMap { row -> String? in
                let columns = row.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard columns.count == 3, columns[0] == pid, columns[2] == server.path else { return nil }
                return String(columns[1])
            }
        let output = try command("/usr/sbin/lsof", [
            "-w", "-nP", "-a", "-p", ([pid] + children).joined(separator: ","), "-Fn",
            desktopDB.path, historyDB.path, queueDB.path,
        ])
        var files: [String: Set<String>] = [:]
        var process: String?
        for line in output.split(separator: "\n") {
            if line.first == "p" {
                process = String(line.dropFirst())
            } else if line.first == "n", let process {
                files[process, default: []].insert(String(line.dropFirst()))
            }
        }
        let owners = children.filter {
            files[$0]?.isSuperset(of: [historyDB.path, queueDB.path]) == true
        }
        guard owners.count == 1, files[pid]?.contains(desktopDB.path) == true else {
            throw CheckError("current desktop processes do not own the expected activity databases")
        }
    }

    func activity(_ time: TimeInterval, _ identity: AppIdentity) throws -> String? {
        try verifyDatabases(identity)
        let first = try writerFiles()
        let desktop = try Database(desktopDB)
        if try desktop.first(
            "SELECT 1 FROM active_chat_turns WHERE profile = ? LIMIT 1", argument: profile.path
        ) != nil {
            return "desktop reports active chats"
        }
        if try desktop.first("""
            SELECT 1 FROM automation_runs
            WHERE status IN ('running', 'pending', 'inProgress', 'in_progress', 'queued') LIMIT 1
            """) != nil {
            return "desktop reports an automation in progress"
        }
        if try Database(queueDB).first("SELECT 1 FROM queued_items LIMIT 1") != nil {
            return "Codex has queued work"
        }
        let history = try Database(historyDB)
        for writer in first {
            let row = try history.first("""
                SELECT status FROM thread_turns WHERE thread_id = ?
                ORDER BY rollout_ordinal DESC LIMIT 1
                """, argument: writer)
            guard let row, let status = row[0], ["completed", "interrupted", "failed"].contains(status) else {
                return "a loaded thread has an active or unknown turn"
            }
        }
        if let recent = try history.first("SELECT max(started_at), max(completed_at) FROM thread_turns") {
            for value in recent.compactMap({ $0 }) {
                guard let timestamp = TimeInterval(value), timestamp.isFinite else {
                    throw CheckError("unexpected turn timestamp")
                }
                if time - timestamp < Self.idleSeconds {
                    return "Codex had turn activity in the last ten minutes"
                }
            }
        }
        return try first == writerFiles() ? nil : "thread ownership changed during the check"
    }

    private func report(_ state: inout State, _ message: String) throws {
        if state.status != message {
            print("\(Date.now.formatted(.iso8601)) \(message)")
            fflush(stdout)
        }
        state.status = message
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }

    private func recover(_ state: inout State, _ pending: Attempt) throws {
        while true {
            let current = try desktop()?.identity
            let age = now - pending.requested
            if let current, current != pending.app {
                let installed = try build(app)
                state.pending = nil
                state.lastAttempt = pending
                let result = installed >= pending.target ? "updated and reopened" : "reopened without applying the update"
                try report(&state, "Build \(installed): \(result)")
                return
            }
            if current != nil, age >= Self.quitTimeout {
                state.pending = nil
                state.lastAttempt = pending
                try report(&state, "Desktop stayed open after the normal quit request")
                return
            }
            if current == nil, age >= 15, try !installerRunning() {
                _ = try command("/usr/bin/open", ["-g", "-a", app.path])
                try report(&state, "Asked macOS to reopen the desktop")
            }
            if age >= 150 {
                // Keep the pending attempt so launchd can resume recovery on the next check.
                try report(&state, "Waiting for Sparkle or desktop relaunch")
                return
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
        }
    }

    func check(_ state: inout State, dryRun: Bool) throws {
        if !dryRun, let pending = state.pending {
            try recover(&state, pending)
            return
        }
        let installed = try build(app)
        guard let target = try stagedBuild(installed) else {
            let message = "Build \(installed): no staged update"
            if dryRun {
                print(message)
            } else if state.idle != nil || state.status != message {
                state.idle = nil
                try report(&state, message)
            }
            return
        }

        let checkedAt = now
        let desktop = try desktop()?.identity
        let blocker = try desktop.map { try activity(checkedAt, $0) } ?? nil
        let message = desktop == nil ? "Desktop is closed" : "Build \(installed) → \(target): \(blocker ?? "idle snapshot")"
        if dryRun {
            print(message)
            return
        }
        guard let desktop, blocker == nil else {
            state.idle = nil
            try report(&state, message)
            return
        }
        if let attempt = state.lastAttempt, attempt.target == target, checkedAt - attempt.requested < Self.retryDelay {
            try report(&state, "Build \(target): waiting before retrying the update")
            return
        }

        let since: TimeInterval
        if let idle = state.idle, idle.app == desktop, idle.target == target,
           checkedAt > idle.last, checkedAt - idle.last <= Self.maxPollGap {
            since = idle.since
        } else {
            since = checkedAt
        }
        state.idle = Idle(app: desktop, target: target, since: since, last: checkedAt)
        guard checkedAt - since >= Self.idleSeconds else {
            try report(&state, "Build \(target): waiting for ten minutes of confirmed idle time")
            return
        }

        guard try self.desktop()?.identity == desktop, try build(app) == installed,
              try stagedBuild(installed) == target, try activity(now, desktop) == nil else {
            state.idle = nil
            try report(&state, "Update deferred because state changed during the final check")
            return
        }

        let pending = Attempt(app: desktop, target: target, requested: now)
        state.idle = nil
        state.pending = pending
        try report(&state, "Build \(installed) → \(target): requesting a normal desktop quit")
        let outcome = try quit(desktop)
        guard outcome == "requested" else {
            state.pending = nil
            state.lastAttempt = pending
            try report(&state, "Quit request: \(outcome)")
            return
        }
        try recover(&state, pending)
    }

    func run(dryRun: Bool) throws {
        if dryRun {
            var state = State()
            try check(&state, dryRun: true)
            return
        }

        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let lock = open(data.appendingPathComponent("run.lock").path, O_CREAT | O_CLOEXEC | O_WRONLY, 0o600)
        guard lock >= 0 else { throw CheckError("could not open the updater lock") }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return }
            throw CheckError("could not acquire the updater lock")
        }

        var state = State()
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // This is the first check.
        }
        do {
            try check(&state, dryRun: false)
        } catch {
            state.idle = nil
            try report(&state, "Deferred because the update or activity check failed (\(error.localizedDescription))")
        }
    }
}

@main
struct Main {
    @MainActor
    static func main() {
        umask(0o077)
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments {
        case [], ["--check"]:
            do {
                try IdleUpdater().run(dryRun: !arguments.isEmpty)
            } catch {
                fputs("codex-idle-update: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        case ["--help"], ["-h"]:
            print("Usage: codex-idle-update [--check]\n  --check  Print a read-only snapshot.")
        default:
            fputs("Usage: codex-idle-update [--check]\n", stderr)
            exit(2)
        }
    }
}
