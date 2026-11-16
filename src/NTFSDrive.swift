// NTFS Drive — menu bar app for read/write NTFS on macOS (macFUSE + ntfs-3g).
// Build with ./build.sh (plain swiftc, no Xcode project needed).

import AppKit
import DiskArbitration
import ServiceManagement
import UserNotifications

// MARK: - Model

struct NTFSPartition {
    let id: String          // e.g. disk4s1
    let disk: String        // e.g. disk4
    let label: String       // volume label or "Partition 1"
    let size: String        // e.g. "101.6 GB"
    var mountPoint: String? // nil = not mounted
    var readWrite: Bool     // true when mounted through macFUSE/ntfs-3g
    var uuid: String?       // stable volume/partition UUID (survives replugging)

    var customName: String? { uuid.flatMap { Settings.names[$0] } }
    var displayName: String { customName ?? label }
    /// Argument for mount-ntfs.sh: "disk4s1" or "disk4s1:Photos".
    var mountArg: String { customName.map { "\(id):\($0)" } ?? id }

    var freeSpace: String? {
        guard let mp = mountPoint,
              let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mp),
              let free = attrs[.systemFreeSize] as? NSNumber else { return nil }
        return ByteCountFormatter.string(fromByteCount: free.int64Value, countStyle: .file)
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum DiskScanner {
    /// All NTFS partitions on external disks, with their current mount state.
    static func scan() -> [NTFSPartition] {
        let list = Shell.run("/usr/sbin/diskutil", ["list", "external"])
        let mounts = Shell.run("/sbin/mount", [])
        var result: [NTFSPartition] = []
        var currentDisk = ""
        let sizeRe = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?\s[KMGT]?B)\s+(disk\d+s\d+)\s*$"#)
        for line in list.split(separator: "\n").map(String.init) {
            if line.hasPrefix("/dev/disk") {
                currentDisk = String(line.split(separator: " ")[0].dropFirst(5))
                continue
            }
            guard line.contains("Windows_NTFS") || line.contains("Microsoft Basic Data") else { continue }
            let ns = line as NSString
            guard let m = sizeRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let size = ns.substring(with: m.range(at: 1))
            let id = ns.substring(with: m.range(at: 2))
            // Name column sits between the type and the size; blank for unlabeled volumes.
            var label = ""
            if let typeRange = line.range(of: line.contains("Windows_NTFS") ? "Windows_NTFS" : "Microsoft Basic Data") {
                let after = line[typeRange.upperBound...]
                if let sizeR = after.range(of: size) {
                    label = after[..<sizeR.lowerBound].trimmingCharacters(in: .whitespaces)
                }
            }
            if label.isEmpty, let n = id.split(separator: "s").last { label = "Partition \(n)" }
            var mp: String? = nil
            var rw = false
            for mline in mounts.split(separator: "\n") where mline.hasPrefix("/dev/\(id) on ") {
                let s = String(mline)
                if let onR = s.range(of: " on "), let parenR = s.range(of: " (", options: .backwards) {
                    mp = String(s[onR.upperBound..<parenR.lowerBound])
                    rw = s[parenR.upperBound...].hasPrefix("macfuse")
                }
            }
            result.append(NTFSPartition(id: id, disk: currentDisk, label: label, size: size,
                                        mountPoint: mp, readWrite: rw, uuid: uuid(for: id)))
        }
        return result
    }

    /// Volume UUID (or partition UUID as a fallback) via DiskArbitration — no subprocess.
    static func uuid(for bsd: String) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return nil }
        for key in [kDADiskDescriptionVolumeUUIDKey, kDADiskDescriptionMediaUUIDKey] {
            if let v = desc[key], CFGetTypeID(v as CFTypeRef) == CFUUIDGetTypeID() {
                return CFUUIDCreateString(kCFAllocatorDefault, (v as! CFUUID)) as String
            }
        }
        return nil
    }
}

/// Same rules as sanitize() in mount-ntfs.sh: a safe single path component, max 32 chars.
func sanitizeName(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.-")
    var n = String(String.UnicodeScalarView(s.unicodeScalars.filter { allowed.contains($0) }).prefix(32))
    while n.hasPrefix(".") { n.removeFirst() }
    return n.trimmingCharacters(in: .whitespaces)
}

// MARK: - Privileged helper (password-free mounting via a narrow sudoers rule)

enum Helper {
    static let dir = "/Library/PrivilegedHelperTools/com.local.ntfsdrive"
    static let sudoers = "/etc/sudoers.d/ntfs-drive"
    static let scripts = ["mount-ntfs", "eject-ntfs"]

    static var installed: Bool {
        FileManager.default.fileExists(atPath: sudoers)
            && scripts.allSatisfy { FileManager.default.isExecutableFile(atPath: "\(dir)/\($0).sh") }
    }
    /// Installed copies match the scripts bundled in this version of the app.
    static var upToDate: Bool {
        scripts.allSatisfy { name in
            guard let bundled = Bundle.main.path(forResource: name, ofType: "sh") else { return false }
            return FileManager.default.contentsEqual(atPath: bundled, andPath: "\(dir)/\(name).sh")
        }
    }
    static var usable: Bool { installed && upToDate }
}

// MARK: - Settings

enum Settings {
    static let d = UserDefaults.standard
    static var autoMount: Bool {
        get { d.object(forKey: "autoMount") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoMount") }
    }
    static var keepClean: Bool {
        get { d.object(forKey: "keepClean") as? Bool ?? true }
        set { d.set(newValue, forKey: "keepClean") }
    }
    /// Custom partition names keyed by volume UUID.
    static var names: [String: String] {
        get { d.dictionary(forKey: "names") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "names") }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var daSession: DASession?
    private var pendingAutoMount: DispatchWorkItem?
    private var busy = false
    private var declinedDisks = Set<String>()   // user cancelled the password prompt; don't nag until replug

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.toolTip = "NTFS Drive"
        menu.delegate = self
        statusItem.menu = menu
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        startDiskWatcher()
        refreshIcon()
        // Opened by hand: show the menu so the user sees something happen. Skip right after
        // login when "Launch at login" started it automatically.
        let startedAtLogin = SMAppService.mainApp.status == .enabled && ProcessInfo.processInfo.systemUptime < 180
        if !startedAtLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showMenuAtMouse() }
        }
    }

    // Rebuild the menu every time it opens so it always shows live state.
    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu() }

    /// Opening the app again (Finder, Dock, Spotlight, Launchpad) pops the menu up at the mouse
    /// pointer, so it's reachable even when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuAtMouse()
        return false
    }

    private func showMenuAtMouse() {
        NSApp.activate(ignoringOtherApps: true)
        buildMenu()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: Menu

    private func buildMenu() {
        menu.removeAllItems()
        let parts = DiskScanner.scan()
        let header = NSMenuItem(title: busy ? "NTFS Drive — working…" : "NTFS Drive", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if parts.isEmpty {
            let none = NSMenuItem(title: "No NTFS drive connected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for p in parts {
            let state: String
            if p.mountPoint == nil { state = "Not mounted" }
            else if p.readWrite { state = "Read/Write" }
            else { state = "Read-only" }
            let free = p.freeSpace.map { " · \($0) free" } ?? ""
            let item = NSMenuItem(title: "\(p.displayName)  —  \(p.size)\(free)", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: p.readWrite ? "checkmark.circle.fill" : "lock.circle",
                                 accessibilityDescription: state)
            let sub = NSMenu()
            let st = NSMenuItem(title: "Status: \(state)  (\(p.id))", action: nil, keyEquivalent: "")
            st.isEnabled = false
            sub.addItem(st)
            sub.addItem(.separator())
            if let mp = p.mountPoint {
                sub.addItem(actionItem("Open in Finder", #selector(openInFinder(_:)), mp))
            }
            if !p.readWrite {
                sub.addItem(actionItem("Mount Read/Write", #selector(mountOne(_:)), p.mountArg))
            }
            if p.uuid != nil {
                sub.addItem(actionItem("Rename…", #selector(rename(_:)), p.id))
            }
            sub.addItem(actionItem("Eject Disk (\(p.disk), all partitions)", #selector(ejectOne(_:)), p.disk))
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let anyRO = parts.contains { !$0.readWrite }
        let mountAll = actionItem("Mount All Read/Write", #selector(mountAll), nil)
        mountAll.isEnabled = anyRO && !busy
        menu.addItem(mountAll)
        let ejectAll = actionItem("Eject All", #selector(ejectAll), nil)
        ejectAll.isEnabled = !parts.isEmpty && !busy
        menu.addItem(ejectAll)

        menu.addItem(.separator())
        let pwTitle = Helper.installed && !Helper.upToDate
            ? "Password-free mounting (update needed…)" : "Password-free mounting"
        menu.addItem(toggleItem(pwTitle, #selector(togglePasswordFree), Helper.installed))
        menu.addItem(toggleItem("Auto-mount when plugged in", #selector(toggleAutoMount), Settings.autoMount))
        menu.addItem(toggleItem("Keep drive clean (no ._ / .DS_Store files)", #selector(toggleClean), Settings.keepClean))
        menu.addItem(toggleItem("Launch at login", #selector(toggleLogin),
                                SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NTFS Drive", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func actionItem(_ title: String, _ sel: Selector, _ obj: Any?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = obj
        return i
    }

    private func toggleItem(_ title: String, _ sel: Selector, _ on: Bool) -> NSMenuItem {
        let i = actionItem(title, sel, nil)
        i.state = on ? .on : .off
        return i
    }

    // MARK: Actions

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let mp = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
    }
    @objc private func mountOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mount([id], automatic: false)
    }
    @objc private func mountAll() {
        mount(DiskScanner.scan().filter { !$0.readWrite }.map(\.mountArg), automatic: false)
    }
    @objc private func rename(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let p = DiskScanner.scan().first(where: { $0.id == id }), let uuid = p.uuid else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename \(p.displayName)"
        alert.informativeText = "Letters, numbers, spaces, - _ . (max 32). Leave empty to use the default name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = p.customName ?? ""
        field.placeholderString = p.label
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var names = Settings.names
        let clean = sanitizeName(field.stringValue)
        names[uuid] = clean.isEmpty ? nil : clean
        Settings.names = names
        if p.readWrite {
            notify("Name saved", "\"\(clean.isEmpty ? p.label : clean)\" shows in Finder the next time the drive is mounted.")
        }
    }
    @objc private func togglePasswordFree() {
        let res = Bundle.main.resourcePath ?? ""
        if Helper.installed && Helper.upToDate {
            let (out, cancelled) = runAdmin("\(res)/uninstall-helper.sh", [])
            if !cancelled { notify("Password-free mounting off", out.isEmpty ? "You'll be asked for your password again." : out) }
        } else {
            // Install, or update copies left by an older version of the app.
            let (out, cancelled) = runAdmin("\(res)/install-helper.sh", [NSUserName(), res])
            if cancelled { return }
            if Helper.usable {
                notify("Password-free mounting on", "Mounting and ejecting won't ask for your password anymore.")
            } else {
                notify("Couldn't enable password-free mounting", String(out.suffix(200)))
            }
        }
    }
    @objc private func ejectOne(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? String else { return }
        eject([d])
    }
    @objc private func ejectAll() { eject([]) }
    @objc private func toggleAutoMount() { Settings.autoMount.toggle() }
    @objc private func toggleClean() {
        Settings.keepClean.toggle()
        notify("Setting saved", "Applies the next time the drive is mounted.")
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            notify("Launch at login", "Couldn't change it: \(error.localizedDescription). Move the app to /Applications and try again.")
        }
    }

    // MARK: Mount / Eject
    // Uses the password-free helper (sudo -n, root-owned script copies) when installed,
    // otherwise the standard macOS admin password prompt.

    private func resource(_ name: String) -> String {
        Bundle.main.path(forResource: name, ofType: "sh") ?? ""
    }

    /// Only partition/disk ids, optionally with a sanitized custom name, are ever passed on.
    private func validArgs(_ args: [String]) -> [String] {
        args.compactMap { a in
            let parts = a.split(separator: ":", maxSplits: 1).map(String.init)
            guard let id = parts.first, id.range(of: #"^disk\d+(s\d+)?$"#, options: .regularExpression) != nil
            else { return nil }
            if parts.count == 2 { let n = sanitizeName(parts[1]); return n.isEmpty ? id : "\(id):\(n)" }
            return id
        }
    }

    private static func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a script as root via `do shell script … with administrator privileges` (password prompt).
    /// Must be called on the main thread. Returns (output, cancelled).
    private func runAdmin(_ script: String, _ args: [String]) -> (String, Bool) {
        let cmd = ([script] + args).map(Self.shQuote).joined(separator: " ") + " 2>&1"
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        let out = NSAppleScript(source: "do shell script \"\(esc)\" with administrator privileges")?
            .executeAndReturnError(&err)
        if let err = err {
            if (err[NSAppleScript.errorNumber] as? Int) == -128 { return ("", true) }
            return ((err[NSAppleScript.errorMessage] as? String) ?? "Unknown error", false)
        }
        return (out?.stringValue ?? "", false)
    }

    /// Runs one of the helper scripts as root; calls back on the main thread with (output, cancelled).
    private func runRoot(_ name: String, _ args: [String], completion: @escaping (String, Bool) -> Void) {
        let args = (name == "mount-ntfs" ? [Settings.keepClean ? "--clean" : "--no-clean"] : []) + validArgs(args)
        if Helper.usable {
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                p.arguments = ["-n", "\(Helper.dir)/\(name).sh"] + args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                var out = ""
                do {
                    try p.run()
                    out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    p.waitUntilExit()
                } catch { out = "password is required" }
                DispatchQueue.main.async {
                    if out.contains("password is required") {
                        // Rule missing or changed: fall back to the password prompt.
                        let r = self.runAdmin(self.resource(name), args)
                        completion(r.0, r.1)
                    } else {
                        completion(out, false)
                    }
                }
            }
        } else {
            // Let the menu close before the password dialog appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let r = self.runAdmin(self.resource(name), args)
                completion(r.0, r.1)
            }
        }
    }

    private func mount(_ args: [String], automatic: Bool) {
        guard !busy else { return }
        busy = true
        runRoot("mount-ntfs", args) { [self] out, cancelled in
            busy = false
            refreshIcon()
            if cancelled {
                if automatic { DiskScanner.scan().forEach { declinedDisks.insert($0.disk) } }
                return
            }
            let ok = out.components(separatedBy: "mounted read/write").count - 1
            let already = out.components(separatedBy: "already mounted").count - 1
            if out.contains("Operation not permitted") {
                notify("macOS blocked disk access",
                       "Add NTFS Drive in System Settings → Privacy & Security → Full Disk Access, then try again.")
            } else if out.contains("unsafe state") || out.contains("hibernat") {
                notify("Drive needs a clean Windows shutdown",
                       "Windows left it hibernated. On a Windows PC, hold Shift while clicking Shut Down, then reconnect.")
            } else if out.contains("FAILED") {
                notify("Mount failed", String(out.suffix(200)))
            } else if ok > 0 {
                notify("Drive ready for writing", "\(ok) partition\(ok == 1 ? "" : "s") mounted read/write.")
            } else if already > 0 && !automatic {
                notify("Already mounted", "The drive is already read/write.")
            }
        }
    }

    private func eject(_ disks: [String]) {
        guard !busy else { return }
        busy = true
        runRoot("eject-ntfs", disks) { [self] out, cancelled in
            busy = false
            refreshIcon()
            if cancelled { return }
            if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("BUSY:") }) {
                notify("Drive is in use", String(line.dropFirst(6)))
            } else if out.contains("safe to unplug") {
                notify("Safe to unplug", "Your NTFS drive was ejected.")
            } else if !out.isEmpty {
                notify("Eject", out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: Auto-mount (DiskArbitration)

    private func startDiskWatcher() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        daSession = session
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx = ctx else { return }
            Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue().diskAppeared(disk)
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx = ctx else { return }
            Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue().diskDisappeared(disk)
        }, ctx)
    }

    private static func isExternalNTFS(_ disk: DADisk) -> String? {
        guard let desc = DADiskCopyDescription(disk) as? [CFString: Any],
              let bsd = desc[kDADiskDescriptionMediaBSDNameKey] as? String,
              bsd.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil else { return nil }
        if (desc[kDADiskDescriptionDeviceInternalKey] as? Bool) == true { return nil }
        let kind = (desc[kDADiskDescriptionVolumeKindKey] as? String ?? "").lowercased()
        let content = desc[kDADiskDescriptionMediaContentKey] as? String ?? ""
        let ntfs = kind == "ntfs" || content == "Windows_NTFS"
            || content.uppercased() == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" // Microsoft Basic Data
        return ntfs ? bsd : nil
    }

    private func diskAppeared(_ disk: DADisk) {
        guard Self.isExternalNTFS(disk) != nil else { return }
        refreshIcon()
        guard Settings.autoMount else { return }
        // Debounce: a drive with several partitions fires several callbacks; macOS also
        // mounts them read-only first. Wait, then mount whatever is not read/write yet.
        pendingAutoMount?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let todo = DiskScanner.scan().filter { !$0.readWrite && !self.declinedDisks.contains($0.disk) }
            if !todo.isEmpty { self.mount(todo.map(\.mountArg), automatic: true) }
        }
        pendingAutoMount = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func diskDisappeared(_ disk: DADisk) {
        if let desc = DADiskCopyDescription(disk) as? [CFString: Any],
           let bsd = desc[kDADiskDescriptionMediaBSDNameKey] as? String,
           bsd.range(of: #"^disk\d+$"#, options: .regularExpression) != nil {
            declinedDisks.remove(bsd)   // replugging resets "don't ask again"
        }
        refreshIcon()
    }

    // MARK: Icon

    private func refreshIcon() {
        let parts = DiskScanner.scan()
        let rw = !parts.isEmpty && parts.allSatisfy(\.readWrite)
        statusItem.button?.appearsDisabled = parts.isEmpty
        statusItem.button?.toolTip = parts.isEmpty ? "NTFS Drive — no drive"
            : (rw ? "NTFS Drive — read/write" : "NTFS Drive — read-only")
    }

    /// Template image: four-pane window glyph (adapts to light/dark menu bar).
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let g: CGFloat = 1.2
            let x0: CGFloat = 2, x1: CGFloat = 16, y0: CGFloat = 2, y1: CGFloat = 16
            let xm = (x0 + x1) / 2, ym = (y0 + y1) / 2
            for r in [NSRect(x: x0, y: ym + g/2, width: xm - x0 - g/2, height: y1 - ym - g/2),
                      NSRect(x: xm + g/2, y: ym + g/2, width: x1 - xm - g/2, height: y1 - ym - g/2),
                      NSRect(x: x0, y: y0, width: xm - x0 - g/2, height: ym - y0 - g/2),
                      NSRect(x: xm + g/2, y: y0, width: x1 - xm - g/2, height: ym - y0 - g/2)] {
                NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: Notifications

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            guard error != nil else { return }
            // Fallback when notifications aren't authorized for an ad-hoc signed app.
            DispatchQueue.main.async {
                let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
                NSAppleScript(source: "display notification \"\(esc(body))\" with title \"\(esc(title))\"")?
                    .executeAndReturnError(nil)
            }
        }
    }
}

// `NTFSDrive --scan` prints detected partitions and exits (handy for troubleshooting).
if CommandLine.arguments.contains("--scan") {
    let parts = DiskScanner.scan()
    if parts.isEmpty { print("No external NTFS partitions found.") }
    for p in parts {
        let state = p.mountPoint == nil ? "not mounted" : (p.readWrite ? "read/write" : "read-only")
        print("\(p.id)\t\(p.disk)\t\(p.displayName)\t\(p.size)\t\(state)\t\(p.mountPoint ?? "-")\t\(p.freeSpace ?? "-") free\tuuid=\(p.uuid ?? "-")")
    }
    print("password-free helper: \(Helper.installed ? (Helper.upToDate ? "installed" : "installed (outdated)") : "not installed")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
