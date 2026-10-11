import AppKit
import ServiceManagement

struct Account: Codable {
    var name: String
    // Folder name under ~/Library/Application Support. "Claude" is the app's own default.
    var folder: String

    var isDefault: Bool { folder == "Claude" }
    var path: String { Store.supportDir.appendingPathComponent(folder).path }
}

enum Store {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    static let configURL = supportDir.appendingPathComponent("ClaudeSwitcher/accounts.json")

    static let seed = [
        Account(name: "Account 1", folder: "Claude"),
        Account(name: "Account 2", folder: "Claude-Desktop"),
        Account(name: "Account 3", folder: "Claude-Desktop-2"),
        Account(name: "Account 4", folder: "Claude-Desktop-3"),
        Account(name: "Account 5", folder: "Claude-Desktop-4"),
    ]

    static func load() -> [Account] {
        if let data = try? Data(contentsOf: configURL),
           let accounts = try? JSONDecoder().decode([Account].self, from: data) {
            return accounts
        }
        save(seed)
        return seed
    }

    static func save(_ accounts: [Account]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(accounts) else { return }
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }
}

enum Identity {
    // Claude Code's own config files are the only local record of account id to email.
    static func emailsByAccountID() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var files = [home.appendingPathComponent(".claude.json")]
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [] {
            if entry.hasPrefix(".claude.json.") {
                files.append(home.appendingPathComponent(entry))
            } else if entry.hasPrefix(".claude-") {
                files.append(home.appendingPathComponent(entry).appendingPathComponent(".claude.json"))
            }
        }
        var emails: [String: String] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = root["oauthAccount"] as? [String: Any],
                  let id = account["accountUuid"] as? String,
                  let email = account["emailAddress"] as? String
            else { continue }
            emails[id] = email
        }
        return emails
    }

    static func accountID(for account: Account) -> String? {
        let url = URL(fileURLWithPath: account.path).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["lastKnownAccountUuid"] as? String
    }

    // Email when known and the name is still the placeholder; two folders on one email show the folder too.
    static func titles(for accounts: [Account]) -> [String] {
        let emails = emailsByAccountID()
        let detected = accounts.map { account -> String? in
            guard account.name.hasPrefix("Account ") else { return nil }
            return accountID(for: account).flatMap { emails[$0] }
        }
        return accounts.indices.map { index in
            guard let email = detected[index] else { return accounts[index].name }
            let shared = detected.filter { $0 == email }.count > 1
            return shared ? "\(email)  (\(accounts[index].folder))" : email
        }
    }
}

struct Usage {
    var fiveHour: Int
    var week: Int
    var sampledAt: Date

    // Last sample the desktop app recorded; it only updates while that instance runs.
    static func latest(for account: Account) -> Usage? {
        let url = URL(fileURLWithPath: account.path).appendingPathComponent("plan-usage-history.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sample = (root["samples"] as? [[String: Any]])?.last,
              let millis = sample["t"] as? Double,
              let used = sample["u"] as? [String: Any]
        else { return nil }
        return Usage(
            fiveHour: (used["fh"] as? NSNumber)?.intValue ?? 0,
            week: (used["sd"] as? NSNumber)?.intValue ?? 0,
            sampledAt: Date(timeIntervalSince1970: millis / 1000))
    }
}

struct CodeSession {
    enum State { case waiting(String?), working, idle, unknown }

    var title: String
    var project: String?
    var state: State
    var since: Date?

    // Every Claude Code process keeps a live status file here; the desktop app doesn't set CLAUDE_CONFIG_DIR.
    static let statusDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    static func load(pid: pid_t) -> CodeSession {
        let url = statusDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return CodeSession(title: "Code session", state: .unknown) }

        let project = (root["cwd"] as? String).map {
            $0.contains("/scratch-workspaces/") ? "Scratch" : URL(fileURLWithPath: $0).lastPathComponent
        }
        let state: State
        switch root["status"] as? String {
        case "waiting": state = .waiting(root["waitingFor"] as? String)
        case "busy": state = .working
        case "idle": state = .idle
        default: state = .unknown
        }
        let name = (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let millis = (root["statusUpdatedAt"] as? Double) ?? (root["startedAt"] as? Double)
        return CodeSession(
            title: name ?? project ?? "Code session", project: project, state: state,
            since: millis.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    var needsYou: Bool {
        if case .waiting = state { return true }
        return false
    }

    var label: String {
        switch state {
        case .waiting("permission prompt"): return "Needs permission"
        case .waiting: return "Needs input"
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Running"
        }
    }

    var color: NSColor {
        switch state {
        case .waiting: return .systemOrange
        case .working: return .systemBlue
        case .idle, .unknown: return .tertiaryLabelColor
        }
    }

    // Sessions waiting on you first, then working, then idle; most recent change first within each.
    var sortKey: (Int, TimeInterval) {
        let rank: Int
        switch state {
        case .waiting: rank = 0
        case .working: rank = 1
        case .idle: rank = 2
        case .unknown: rank = 3
        }
        return (rank, -(since?.timeIntervalSince1970 ?? 0))
    }

    func detail(now: Date = Date()) -> String {
        var text = label
        if let since, now.timeIntervalSince(since) >= 60 {
            text += " " + shortDuration(now.timeIntervalSince(since))
        }
        if let project, project != title {
            text += "  ·  " + project
        }
        return text
    }
}

func shortDuration(_ interval: TimeInterval) -> String {
    let minutes = Int(interval / 60)
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 24 * 60 { return "\(minutes / 60)h" }
    return "\(minutes / (24 * 60))d"
}

struct ProcessSnapshot {
    static let appPath = "/Applications/Claude.app"
    static let appBinary = appPath + "/Contents/MacOS/Claude"

    var mainPid: [String: pid_t] = [:]
    var codeSessions: [String: [CodeSession]] = [:]

    static func take(_ accounts: [Account]) -> ProcessSnapshot {
        var snapshot = ProcessSnapshot()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return snapshot }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()

        for line in output.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<space]) else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])

            if command == appBinary || command.hasPrefix(appBinary + " ") {
                if let flag = command.range(of: "--user-data-dir=") {
                    let value = command[flag.upperBound...]
                    if let match = accounts.first(where: { value == $0.path || value.hasPrefix($0.path + " --") }) {
                        snapshot.mainPid[match.folder] = pid
                    }
                } else if let match = accounts.first(where: \.isDefault) {
                    snapshot.mainPid[match.folder] = pid
                }
            } else if let match = accounts.first(where: { command.hasPrefix($0.path + "/claude-code/") }) {
                snapshot.codeSessions[match.folder, default: []].append(CodeSession.load(pid: pid))
            }
        }
        for folder in snapshot.codeSessions.keys {
            snapshot.codeSessions[folder]?.sort { $0.sortKey < $1.sortKey }
        }
        return snapshot
    }
}

func statusLine(_ account: Account, _ snapshot: ProcessSnapshot, now: Date = Date()) -> String {
    var parts: [String] = []
    if snapshot.mainPid[account.folder] != nil {
        let sessions = snapshot.codeSessions[account.folder] ?? []
        var running = sessions.isEmpty
            ? "Running" : "Running, \(sessions.count) Code session\(sessions.count == 1 ? "" : "s")"
        let waiting = sessions.filter(\.needsYou).count
        if waiting > 0 { running += ", \(waiting) need\(waiting == 1 ? "s" : "") you" }
        parts.append(running)
    } else {
        parts.append("Not running")
    }
    if let usage = Usage.latest(for: account) {
        let age = RelativeDateTimeFormatter()
        age.unitsStyle = .abbreviated
        let when = now.timeIntervalSince(usage.sampledAt) < 60
            ? "just now" : age.localizedString(for: usage.sampledAt, relativeTo: now)
        parts.append("5h \(usage.fiveHour)%  week \(usage.week)%  (\(when))")
    } else if !FileManager.default.fileExists(atPath: account.path) {
        parts.append("never opened")
    }
    return parts.joined(separator: "  ·  ")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var accounts: [Account] = []
    private var titles: [String] = []
    private var snapshot = ProcessSnapshot()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        rebuildMenu()
    }

    private func refresh() {
        accounts = Store.load()
        titles = Identity.titles(for: accounts)
        snapshot = ProcessSnapshot.take(accounts)
        let running = snapshot.mainPid.count
        statusItem.button?.image = NSImage(
            systemSymbolName: "person.2.fill", accessibilityDescription: "Claude accounts")
        statusItem.button?.title = running > 0 ? " \(running)" : ""
        statusItem.button?.imagePosition = .imageLeading
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        for (index, account) in accounts.enumerated() {
            let isRunning = snapshot.mainPid[account.folder] != nil
            let item = NSMenuItem(
                title: titles[index], action: #selector(openAccount(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.target = self
            item.tag = index
            item.subtitle = statusLine(account, snapshot)
            item.image = dot(isRunning ? .systemGreen : .tertiaryLabelColor)
            if isRunning {
                item.submenu = sessionMenu(for: index, keyEquivalent: item.keyEquivalent)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        add("Rename Account…", #selector(renameAccount))
        add("Edit Accounts File…", #selector(editAccounts))
        let login = add("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add("Quit Claude Switcher", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
    }

    // An item with a submenu never sends its own action, so switching and quitting live inside it.
    private func sessionMenu(for index: Int, keyEquivalent: String) -> NSMenu {
        let submenu = NSMenu()
        let switchItem = NSMenuItem(
            title: "Switch to \(titles[index])", action: #selector(openAccount(_:)), keyEquivalent: keyEquivalent)
        switchItem.target = self
        switchItem.tag = index
        submenu.addItem(switchItem)
        submenu.addItem(.separator())

        let sessions = snapshot.codeSessions[accounts[index].folder] ?? []
        if sessions.isEmpty {
            let none = NSMenuItem(title: "No Code sessions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        let now = Date()
        for session in sessions {
            let title = session.title.count > 48 ? String(session.title.prefix(47)) + "…" : session.title
            let row = NSMenuItem(title: title, action: #selector(openAccount(_:)), keyEquivalent: "")
            row.target = self
            row.tag = index
            row.subtitle = session.detail(now: now)
            row.image = dot(session.color)
            submenu.addItem(row)
        }

        submenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(titles[index])", action: #selector(quitAccount(_:)), keyEquivalent: "")
        quit.target = self
        quit.tag = index
        submenu.addItem(quit)
        return submenu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    private func dot(_ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    @objc private func openAccount(_ sender: NSMenuItem) {
        let account = accounts[sender.tag]
        if let pid = snapshot.mainPid[account.folder],
           let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            app.activate(options: [.activateAllWindows])
            return
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-a", ProcessSnapshot.appPath]
            + (account.isDefault ? [] : ["--args", "--user-data-dir=\(account.path)"])
        try? open.run()
    }

    @objc private func quitAccount(_ sender: NSMenuItem) {
        let account = accounts[sender.tag]
        guard let pid = snapshot.mainPid[account.folder] else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    @objc private func renameAccount() {
        let alert = NSAlert()
        alert.messageText = "Rename Account"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 260, height: 26))
        picker.addItems(withTitles: accounts.indices.map { "\(titles[$0])  (\(accounts[$0].folder))" })
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "New name, like Work or Personal"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        stack.addSubview(picker)
        stack.addSubview(field)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, accounts.indices.contains(picker.indexOfSelectedItem) else { return }
        accounts[picker.indexOfSelectedItem].name = name
        Store.save(accounts)
    }

    @objc private func editAccounts() {
        _ = Store.load()
        NSWorkspace.shared.open(
            [Store.configURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

if CommandLine.arguments.contains("--dump") {
    let accounts = Store.load()
    let snapshot = ProcessSnapshot.take(accounts)
    let titles = Identity.titles(for: accounts)
    for (index, account) in accounts.enumerated() {
        print("\(titles[index]) [\(account.folder)]: \(statusLine(account, snapshot))")
        for session in snapshot.codeSessions[account.folder] ?? [] {
            print("    \(session.title): \(session.detail())")
        }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
