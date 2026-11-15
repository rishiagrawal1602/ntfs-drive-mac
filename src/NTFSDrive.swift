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
                                        mountPoint: mp, readWrite: rw))
        }
        return result
    }
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
    }

    // Rebuild the menu every time it opens so it always shows live state.
    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu() }

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
            let item = NSMenuItem(title: "\(p.label)  —  \(p.size)\(free)", action: nil, keyEquivalent: "")
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
                sub.addItem(actionItem("Mount Read/Write", #selector(mountOne(_:)), p.id))
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
    @objc private func mountAll() { mount([], automatic: false) }
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

    // MARK: Mount / Eject (privileged via the standard macOS admin prompt)

    private func resource(_ name: String) -> String {
        Bundle.main.path(forResource: name, ofType: "sh") ?? ""
    }

    /// Runs a bundled script as root via `do shell script … with administrator privileges`.
    /// Returns (output, cancelled).
    private func runPrivileged(_ script: String, env: String, args: [String]) -> (String, Bool) {
        let safeArgs = args.filter { $0.range(of: #"^disk\d+(s\d+)?$"#, options: .regularExpression) != nil }
        let cmd = ([env, "'\(script)'"] + safeArgs).joined(separator: " ") + " 2>&1"
        let src = "do shell script \"\(cmd)\" with administrator privileges"
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err = err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return ("", true) }
            return ((err[NSAppleScript.errorMessage] as? String) ?? "Unknown error", false)
        }
        return (out?.stringValue ?? "", false)
    }

    private func mount(_ ids: [String], automatic: Bool) {
        guard !busy else { return }
        busy = true
        let env = "NTFS_CLEAN=\(Settings.keepClean ? 1 : 0)"
        // Let the menu close / UI settle before the password dialog appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            let (out, cancelled) = runPrivileged(resource("mount-ntfs"), env: env, args: ids)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            let (out, cancelled) = runPrivileged(resource("eject-ntfs"), env: "", args: disks)
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
            if !todo.isEmpty { self.mount(todo.map(\.id), automatic: true) }
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
        print("\(p.id)\t\(p.disk)\t\(p.label)\t\(p.size)\t\(state)\t\(p.mountPoint ?? "-")\t\(p.freeSpace ?? "-") free")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
