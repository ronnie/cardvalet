import Cocoa
import LocalAuthentication
import WebKit

// MARK: decision logic (pure, self-tested)
enum PinAction { case ignore, pause, enter }
/// Seconds since our last PIN submit. <3s: same dialog still closing. 3-8s: dialog is back, PIN probably wrong, stop (CAC locks after 3 bad tries).
func decide(sinceLastSubmit s: TimeInterval?) -> PinAction {
    guard let s else { return .enter }
    return s < 3 ? .ignore : (s < 8 ? .pause : .enter)
}

/// Pure parser/judge for `pkcs11-tool -L` output. Checks EVERY token, so a YubiKey listed before the card cannot hide a locked card.
func judge(_ text: String) -> (ok: Bool, reason: String, detail: String) {
    var tokens: [(label: String, flags: String)] = []
    var label = ""
    func value(_ l: Substring) -> String { l.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
    for line in text.split(separator: "\n") {
        if line.hasPrefix("Slot ") { label = "" }
        else if line.contains("token label") { label = value(line) }
        else if line.contains("token flags") { tokens.append((label, value(line))) }
    }
    guard !tokens.isEmpty else { return text.contains("(empty)") ? (false, "NOCARD", "") : (false, "Card status unreadable (no reader?).", "") }
    for t in tokens {
        let detail = tokens.count > 1 ? t.label : ""
        if t.flags.contains("locked") { return (false, "LOCKED", detail) }
        if t.flags.contains("final try") { return (false, "FINAL TRY: one wrong PIN will lock the card.", detail) }
        if t.flags.contains("count low") { return (false, "PIN retry count is LOW.", detail) }
    }
    return (true, "", "")
}

// MARK: allowed sites (hosts CardValet may click the certificate dialog for)
let defaultHosts = [".dso.mil"]
/// "*.Example.COM", ".example.com" and " example.com " all become "example.com".
func normalizeHost(_ s: String) -> String {
    var h = s.trimmingCharacters(in: .whitespaces).lowercased()
    if h.hasPrefix("*.") { h.removeFirst(2) }
    if h.hasPrefix(".") { h.removeFirst() }
    return h
}
/// Needs at least two labels, so "com" or "mil" alone is rejected as too broad.
func validHostEntry(_ s: String) -> Bool {
    s.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", options: .regularExpression) != nil
}
/// Host from Chrome's "Select a certificate to authenticate yourself to host:443" text.
func certHost(from text: String) -> String? {
    guard let r = text.range(of: "authenticate yourself to ") else { return nil }
    var host = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    if let c = host.lastIndex(of: ":"), host[host.index(after: c)...].allSatisfy({ $0.isNumber }) { host = String(host[..<c]) }
    return host.isEmpty ? nil : host.lowercased()
}
/// An entry matches the host itself and every subdomain of it.
func hostAllowed(_ host: String, _ allowed: [String]) -> Bool {
    allowed.map(normalizeHost).contains { !$0.isEmpty && (host == $0 || host.hasSuffix("." + $0)) }
}

if CommandLine.arguments.contains("--check-card") { // read-only: prints what the pre-typing card check sees
    let r = cardSafe(); print("ok=\(r.ok) reason='\(r.reason)' detail='\(r.detail)'"); exit(r.ok ? 0 : 1)
}

if CommandLine.arguments.contains("--selftest") {
    precondition(decide(sinceLastSubmit: nil) == .enter)
    precondition(decide(sinceLastSubmit: 1) == .ignore)
    precondition(decide(sinceLastSubmit: 5) == .pause)
    precondition(decide(sinceLastSubmit: 30) == .enter)
    let ok = "Slot 0 (0x0): R\n  token label        : CAC\n  token flags        : login required, PIN initialized\n"
    let yk = "Slot 0 (0x0): R\n  token label        : YubiKey\n  token flags        : login required, PIN initialized\n"
    precondition(judge(ok).ok)
    precondition(judge("Slot 0 (0x0): R\n  (empty)\n").reason == "NOCARD")
    precondition(judge("").reason.hasPrefix("Card status unreadable"))
    let lockedCard = ok.replacingOccurrences(of: "PIN initialized", with: "PIN initialized, user PIN locked")
    precondition(judge(lockedCard).reason == "LOCKED" && judge(lockedCard).detail == "")
    let both = judge(yk + lockedCard.replacingOccurrences(of: "Slot 0", with: "Slot 1"))
    precondition(both.reason == "LOCKED" && both.detail == "CAC") // locked card behind a healthy token is still caught
    precondition(judge(ok.replacingOccurrences(of: "PIN initialized", with: "user PIN count low")).reason.contains("LOW"))
    let t = "Select a certificate to authenticate yourself to Login.AFWERX.dso.mil:443"
    precondition(certHost(from: t) == "login.afwerx.dso.mil")
    precondition(certHost(from: "Select a certificate to authenticate yourself to example.com") == "example.com")
    precondition(certHost(from: "Something else") == nil)
    precondition(hostAllowed("login.afwerx.dso.mil", defaultHosts))
    precondition(hostAllowed("dso.mil", defaultHosts))
    precondition(!hostAllowed("evil-dso.mil", defaultHosts) && !hostAllowed("dso.mil.evil.com", defaultHosts) && !hostAllowed("notdso.mil", ["dso.mil"]))
    precondition(!hostAllowed("anything.com", []) && !hostAllowed("a.com", [""]))
    precondition(normalizeHost(" *.Example.COM ") == "example.com" && normalizeHost(".dso.mil") == "dso.mil")
    precondition(validHostEntry("dso.mil") && validHostEntry("a-b.example.co.uk") && !validHostEntry("mil") && !validHostEntry("a b.com") && !validHostEntry("-a.com") && !validHostEntry("a..com"))
    print("selftest ok"); exit(0)
}

// MARK: Accessibility helpers
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ k: String) -> String { attr(e, k) as? String ?? "" }
func kids(_ e: AXUIElement, _ k: String = "AXChildren") -> [AXUIElement] { attr(e, k) as? [AXUIElement] ?? [] }
func find(_ e: AXUIElement, depth: Int = 0, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
    if pred(e) { return e }
    if depth > 12 { return nil }
    for c in kids(e) { if let f = find(c, depth: depth + 1, pred) { return f } }
    return nil
}
/// Run an alert above the macOS PIN prompt (coreautha sits at window level 1000, so a normal alert opens hidden behind it).
func present(_ a: NSAlert) -> NSApplication.ModalResponse {
    // runModal resets the level to the modal-panel level, so raise it again once the modal loop is running
    DispatchQueue.main.async { a.window.level = NSWindow.Level(rawValue: 1001); a.window.orderFrontRegardless() }
    return a.runModal()
}
func press(_ e: AXUIElement) { AXUIElementPerformAction(e, "AXPress" as CFString) }
func tap(_ vk: CGKeyCode, _ chars: [UniChar] = [], pid: pid_t) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: down)
        if !chars.isEmpty { e?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars) }
        e?.postToPid(pid) // straight to coreautha, not whatever app is frontmost
    }
}

func log(_ m: String) {
    let f = NSHomeDirectory() + "/Library/Logs/CardValet.log"
    let line = "\(Date()) \(m)\n"
    if let h = FileHandle(forWritingAtPath: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
    else { try? line.write(toFile: f, atomically: true, encoding: .utf8) }
}

/// Read-only card status check (never sends a PIN). Fails closed, including on a 5s timeout.
func cardSafe() -> (ok: Bool, reason: String, detail: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/local/bin/pkcs11-tool")
    p.arguments = ["--module", "/Library/OpenSC/lib/opensc-pkcs11.so", "-L"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }
    guard (try? p.run()) != nil else { log("cardSafe: pkcs11-tool failed to run"); return (false, "Card status unreadable (pkcs11-tool failed).", "") }
    if done.wait(timeout: .now() + 5) == .timedOut {
        p.terminate(); log("cardSafe: timed out")
        return (false, "Card status check timed out (reader or card not responding).", "")
    }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let r = judge(text)
    log("cardSafe: ok=\(r.ok) reason='\(r.reason)' detail='\(r.detail)'")
    return r
}

final class App: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var enabled = true
    var busy = false
    var lastCert = Date.distantPast
    var lastSubmit: Date?
    var noPinUntil = Date.distantPast
    var axChrome = Set<pid_t>()
    var alertColor: NSColor?
    var lastIgnoredLog = Date.distantPast
    var authorizedUntil = Date.distantPast // Touch ID / password was confirmed at the certificate step
    var authDeniedUntil = Date.distantPast
    var hintWindow: NSPanel?
    var allowedHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: "allowedHosts") ?? defaultHosts }
        set { UserDefaults.standard.set(newValue, forKey: "allowedHosts") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--preview-nopin") { noPinAlert(preview: true); exit(0) }
        if CommandLine.arguments.contains("--preview-accessibility") { accessibilityAlert(); exit(0) }
        if CommandLine.arguments.contains("--preview-nocard") { cardAlert("NOCARD", preview: true); exit(0) }
        if CommandLine.arguments.contains("--preview-locked") { cardAlert("LOCKED", preview: true); exit(0) } // look only, touches nothing
        let trusted = AXIsProcessTrusted() // no system prompt: our own alert below explains it better
        log("started, accessibility trusted=\(trusted)")
        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        if !trusted { accessibilityAlert() }
        else if Keychain.has() { readPinWithHint { _ in log("keychain access check done") } } // shows any Keychain prompt now, not later behind the PIN prompt
    }

    // MARK: menu
    func buildMenu() {
        if let img = NSImage(systemSymbolName: "person.text.rectangle", accessibilityDescription: "CardValet") {
            item.button?.image = img; item.button?.title = ""
        } else { item.button?.title = "CardValet" }
        item.button?.contentTintColor = alertColor
        item.button?.alphaValue = (enabled || alertColor != nil) ? 1 : 0.4
        item.button?.toolTip = enabled ? "CardValet" : "CardValet (paused)"
        let m = NSMenu()
        let en = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: ""); en.target = self
        en.state = enabled ? .on : .off
        let tid = NSMenuItem(title: "Require Touch ID / password", action: #selector(toggleTouchID), keyEquivalent: ""); tid.target = self
        tid.state = UserDefaults.standard.bool(forKey: "touchid") ? .on : .off
        let pin = NSMenuItem(title: "Set PIN...", action: #selector(setPin), keyEquivalent: ""); pin.target = self
        let help = NSMenuItem(title: "Help", action: #selector(showHelp), keyEquivalent: ""); help.target = self
        let sites = NSMenuItem(title: "Allowed Sites...", action: #selector(editAllowedSites), keyEquivalent: ""); sites.target = self
        let del = NSMenuItem(title: "Forget PIN", action: #selector(deletePin), keyEquivalent: ""); del.target = self
        m.addItem(en); m.addItem(tid); m.addItem(sites); m.addItem(pin); m.addItem(del); m.addItem(help); m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = m
    }
    @objc func toggleEnabled() { enabled.toggle(); alertColor = nil; lastSubmit = nil; buildMenu() }
    @objc func toggleTouchID() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "touchid"), forKey: "touchid"); buildMenu() }
    @objc func editAllowedSites() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "ALLOWED SITES"
        a.informativeText = "CardValet clicks Chrome's certificate dialog only for these sites. Separate them with commas. An entry such as dso.mil also covers every address that ends in .dso.mil. Only add sites you trust."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); f.stringValue = allowedHosts.joined(separator: ", ")
        a.accessoryView = f; a.window.initialFirstResponder = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Reset to Default"); a.addButton(withTitle: "Cancel")
        let r = present(a)
        if r == .alertSecondButtonReturn { allowedHosts = defaultHosts; log("allowed sites reset to default"); return }
        guard r == .alertFirstButtonReturn else { return }
        let entries = f.stringValue.split(whereSeparator: { ", \n;".contains($0) }).map { normalizeHost(String($0)) }.filter { !$0.isEmpty }
        let bad = entries.filter { !validHostEntry($0) }
        guard !entries.isEmpty, bad.isEmpty else {
            let m = NSAlert(); m.messageText = entries.isEmpty ? "Add at least one site. Nothing saved." : "Not a valid site name: \(bad.joined(separator: ", ")). Nothing saved."
            m.informativeText = "Use names with at least two parts, such as dso.mil or example.com."; present(m); return
        }
        allowedHosts = entries; log("allowed sites saved: \(entries.joined(separator: ", "))")
    }
    /// Greys out Forget PIN when there is nothing to delete.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(deletePin) ? Keychain.has() : true
    }
    @objc func deletePin() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "Forget your saved PIN?"
        a.informativeText = "CardValet will stop filling in the PIN prompt until you save a new PIN with Set PIN."
        a.addButton(withTitle: "Forget PIN"); a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        guard present(a) == .alertFirstButtonReturn else { return }
        let ok = Keychain.delete(); log("pin forgotten, success=\(ok)")
        if !ok { let m = NSAlert(); m.messageText = "The saved PIN could not be removed."; m.informativeText = "Open Keychain Access, search for cardvalet and delete it there."; present(m) }
    }
    var helpWindow: NSWindow?
    @objc func showHelp() {
        if helpWindow == nil {
            let web = WKWebView(frame: .zero)
            if let page = Bundle.main.url(forResource: "help", withExtension: "html"), let dir = Bundle.main.resourceURL {
                web.loadFileURL(page, allowingReadAccessTo: dir) // file access so the screenshots load
            } else { web.loadHTMLString("<p>help.html not found in the app bundle.</p>", baseURL: nil) }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "CardValet Help"; w.contentView = web; w.isReleasedWhenClosed = false; w.minSize = NSSize(width: 480, height: 400); w.center()
            helpWindow = w
        }
        NSApp.activate(ignoringOtherApps: true); helpWindow?.makeKeyAndOrderFront(nil)
    }
    var pinRows: [(secure: NSSecureTextField, plain: NSTextField)] = []
    @objc func togglePinVisibility(_ b: NSButton) {
        let show = b.state == .on
        for r in pinRows {
            if show { r.plain.stringValue = r.secure.stringValue } else { r.secure.stringValue = r.plain.stringValue }
            r.secure.isHidden = show; r.plain.isHidden = !show
        }
    }
    @discardableResult @objc func setPin() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "ENTER YOUR CARD PIN"; a.informativeText = "Enter it twice. The PIN is stored in your Apple login Keychain."
        pinRows = []
        var rows: [NSView] = []
        for ph in ["PIN", "Confirm PIN"] {
            let sec = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); sec.placeholderString = ph
            let pl = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); pl.placeholderString = ph; pl.isHidden = true
            let row = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); row.addSubview(sec); row.addSubview(pl)
            row.widthAnchor.constraint(equalToConstant: 220).isActive = true
            row.heightAnchor.constraint(equalToConstant: 24).isActive = true
            pinRows.append((sec, pl)); rows.append(row)
        }
        let show = NSButton(checkboxWithTitle: "Show PIN", target: self, action: #selector(togglePinVisibility(_:)))
        let box = NSStackView(views: rows + [show]); box.orientation = .vertical; box.spacing = 8; box.alignment = .leading
        box.frame = NSRect(x: 0, y: 0, width: 220, height: 82) // 2 x 24 + checkbox 18 + 2 x 8 gaps, explicit so nothing is clipped
        a.accessoryView = box; a.window.initialFirstResponder = pinRows[0].secure
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        guard present(a) == .alertFirstButtonReturn else { return false }
        let showing = show.state == .on
        let v1 = showing ? pinRows[0].plain.stringValue : pinRows[0].secure.stringValue
        let v2 = showing ? pinRows[1].plain.stringValue : pinRows[1].secure.stringValue
        guard !v1.isEmpty else { return false }
        guard v1.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil else {
            let m = NSAlert(); m.messageText = "The PIN must be 4 to 8 digits. Nothing saved."; present(m); return false // card reports pin min/max 4/8
        }
        guard v1 == v2 else {
            let m = NSAlert(); m.messageText = "PINs did not match. Nothing saved."; present(m); return false
        }
        Keychain.save(v1); log("pin saved, \(v1.count) chars")
        let n = NSAlert(); n.messageText = "PIN SAVED"
        n.informativeText = "macOS may now ask to let CardValet read your PIN. If it does, enter your Mac user password and click Always Allow."
        n.addButton(withTitle: "Continue"); present(n)
        readPinWithHint { _ in log("keychain access check done") } // brings up the prompt now
        return true
    }
    /// Shown when a PIN prompt appears but no PIN has been saved yet. Nothing is typed.
    func noPinAlert(preview: Bool = false) {
        if !preview { enabled = false; lastSubmit = nil; alertColor = .systemOrange; buildMenu() }
        NSSound.beep()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.alertStyle = .critical
        let cfg = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular).applying(.init(paletteColors: [.systemOrange]))
        a.icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        a.messageText = "NO PIN SAVED"
        a.informativeText = "CardValet needs your card PIN to sign you in, but you have not saved one yet.\n\nClick Set PIN Now and enter your PIN. CardValet will then finish signing you in using the prompt that is already open.\n\nPrefer to type it yourself? Click Later. CardValet stays off until you turn Enabled back on in the menu."
        a.addButton(withTitle: "Set PIN Now"); a.addButton(withTitle: "Later")
        guard present(a) == .alertFirstButtonReturn, !preview else { return }
        if setPin() { enabled = true; alertColor = nil; buildMenu() }
    }

    /// Shown when macOS has not granted (or has gone stale on) the Accessibility permission.
    func accessibilityAlert() {
        NSSound.beep()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.alertStyle = .critical
        let cfg = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular).applying(.init(paletteColors: [.systemOrange]))
        a.icon = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        a.messageText = "ACCESSIBILITY ACCESS NEEDED"
        a.informativeText = """
        CardValet needs Accessibility access to click the certificate dialog and enter your PIN. Until it is enabled, CardValet does nothing.

        1. Click "Open Accessibility Settings" below.
        2. Find CardValet in the list and switch it on.
        3. If CardValet is already listed, select it, click the minus (-) button to remove it, then add it again with the plus (+) button and switch it on. Finder will show CardValet.app so you can drag it in.
        4. CardValet quits when you close this alert. Reopen it once access is enabled.
        """
        a.addButton(withTitle: "Open Accessibility Settings"); a.addButton(withTitle: "Later")
        if present(a) == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        log("accessibility alert closed, quitting")
        NSApp.terminate(nil) // an untrusted menu bar app does nothing, so do not leave it running
    }

    /// Loud, unmissable alert. Nothing was typed.
    func cardAlert(_ reason: String, detail: String = "", preview: Bool = false) {
        if !preview {
            enabled = false; lastSubmit = nil
            alertColor = reason == "LOCKED" ? .systemRed : .systemOrange
            buildMenu()
        }
        NSSound.beep()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.alertStyle = .critical
        let locked = reason == "LOCKED", noCard = reason == "NOCARD"
        let cfg = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular).applying(.init(paletteColors: [locked ? .systemRed : .systemOrange]))
        let sym = locked ? "lock.fill" : (noCard ? "creditcard.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill")
        a.icon = (NSImage(systemSymbolName: sym, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil))?.withSymbolConfiguration(cfg)
        a.messageText = locked ? "YOUR CARD IS LOCKED" : (noCard ? "NO CARD DETECTED" : "CAC PIN WARNING")
        a.informativeText = locked
            ? "The card is user PIN locked.\n\nHit Cancel on the PIN prompt, and then unlock your card before trying again. You can use the ActivClient Windows app or visit an ID office or CAC PIN reset station to unlock it."
            : (noCard
                ? "The reader is connected but no card is in it.\n\nHit Cancel on the PIN prompt, insert your card, then try again. Nothing was typed."
                : reason + " NOTHING WAS TYPED. Cancel the PIN prompt and check the card.")
        if !detail.isEmpty { a.informativeText += "\n\nToken: \(detail)" }
        a.addButton(withTitle: "OK, I understand")
        present(a)
    }
    func pause(_ why: String) {
        enabled = false; lastSubmit = nil; buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "CardValet paused"; a.informativeText = why; present(a)
    }

    // MARK: poll
    func tick() {
        guard enabled, !busy, AXIsProcessTrusted() else { return }
        handleCert()
        handlePin()
    }

    /// Stage 1: Chrome "Select a certificate" for a host in Allowed Sites -> press OK.
    func handleCert() {
        guard Date().timeIntervalSince(lastCert) > 2 else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome") {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            if axChrome.insert(app.processIdentifier).inserted {
                AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, true as CFTypeRef)
            }
            for w in kids(ax, "AXWindows") where str(w, "AXTitle") == "Select a certificate" {
                let host = find(w, { certHost(from: str($0, "AXValue")) != nil }).flatMap { certHost(from: str($0, "AXValue")) }
                guard let host, hostAllowed(host, allowedHosts) else {
                    if Date().timeIntervalSince(lastIgnoredLog) > 5 { lastIgnoredLog = Date(); log("cert dialog for \(host ?? "unknown site") is not in Allowed Sites, left alone") }
                    continue
                }
                guard let ok = find(w, { str($0, "AXRole") == "AXButton" && str($0, "AXTitle") == "OK" }) else { continue }
                if requireAuth && Date() > authorizedUntil { // ask now, while nothing else is on screen
                    if Date() < authDeniedUntil { return }
                    busy = true; lastCert = Date()
                    authenticate("sign in with your card") { [self] granted in
                        busy = false
                        if granted { authorizedUntil = Date().addingTimeInterval(60); press(ok); lastCert = Date(); log("authenticated, pressed cert OK") }
                        else { authDeniedUntil = Date().addingTimeInterval(30); log("authentication cancelled, certificate dialog left alone") }
                    }
                    return
                }
                press(ok); lastCert = Date(); log("pressed cert OK"); return
            }
        }
    }

    /// Stage 2: coreautha "Google Chrome is trying to sign data" -> fill PIN, submit.
    func handlePin() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let w = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "coreautha" }),
              let pid = w[kCGWindowOwnerPID as String] as? pid_t else { return }
        guard let win = kids(AXUIElementCreateApplication(pid), "AXWindows").first(where: {
            find($0, { str($0, "AXValue").contains("Google Chrome is trying to sign data") }) != nil }) else { return }
        switch decide(sinceLastSubmit: lastSubmit.map { Date().timeIntervalSince($0) }) {
        case .ignore: return
        case .pause: pause("The PIN prompt came back right after submitting. The PIN may be wrong. Stopped to avoid locking the card."); return
        case .enter: break
        }
        guard Date() > noPinUntil,
              let field = find(win, { str($0, "AXSubrole") == "AXSecureTextField" }),
              let ok = find(win, { str($0, "AXRole") == "AXButton" && str($0, "AXDescription") == "OK" }) else { return }
        let card = cardSafe()
        guard card.ok else { cardAlert(card.reason, detail: card.detail); return }
        guard Keychain.has() else { noPinAlert(); return }
        busy = true
        fetchPin { [self] pin in
            guard let pin else { noPinUntil = Date().addingTimeInterval(10); busy = false; NSSound.beep(); return }
            log("pin prompt found, typing")
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(axApp, "AXFrontmost" as CFString, true as CFTypeRef)
            AXUIElementPerformAction(win, "AXRaise" as CFString)
            AXUIElementSetAttributeValue(field, "AXFocused" as CFString, true as CFTypeRef)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                for c in pin.utf16 { tap(0, [c], pid: pid) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                    let got = str(field, "AXValue").count
                    log("field reports \(got) chars, expected \(pin.count), OK enabled=\(String(describing: attr(ok, "AXEnabled")))")
                    busy = false
                    // shortcut: a secure field may report 0 chars; only abort on a clear mismatch
                    if got != 0 && got != pin.count { pause("The PIN field did not contain the expected number of characters. Nothing was submitted. Cancel the prompt and re-set the PIN."); return }
                    guard (attr(ok, "AXEnabled") as? Bool) == true else {
                        pause("The OK button stayed disabled after typing the PIN, so nothing was submitted. Cancel the prompt and re-check the saved PIN."); return
                    }
                    press(ok); lastSubmit = Date(); log("pressed OK")
                }
            }
        }
    }

    var requireAuth: Bool { UserDefaults.standard.bool(forKey: "touchid") }

    func authenticate(_ reason: String, _ done: @escaping (Bool) -> Void) {
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    func fetchPin(_ done: @escaping (String?) -> Void) {
        if requireAuth && Date() > authorizedUntil { // fallback: no certificate step ran, so ask here
            authenticate("use your card PIN") { [self] ok in ok ? readPinWithHint(done) : done(nil) }
        } else { readPinWithHint(done) }
    }

    /// Reads the PIN off the main thread. If macOS shows a Keychain prompt (it can hide behind the PIN prompt), a hint panel says where to look.
    func readPinWithHint(_ done: @escaping (String?) -> Void) {
        let hint = DispatchWorkItem { [weak self] in self?.showKeychainHint() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: hint)
        DispatchQueue.global().async { [weak self] in
            let pin = Keychain.read()
            DispatchQueue.main.async { hint.cancel(); self?.hintWindow?.close(); self?.hintWindow = nil; done(pin) }
        }
    }

    func showKeychainHint() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "CardValet is waiting for Keychain access"; p.level = NSWindow.Level(rawValue: 1001)
        let l = NSTextField(wrappingLabelWithString: "macOS is asking to let CardValet read your saved PIN. Enter your Mac user password and click Always Allow. If you cannot see the prompt, it may be behind the PIN prompt: move the PIN prompt aside.")
        l.frame = NSRect(x: 16, y: 12, width: 388, height: 80); p.contentView?.addSubview(l)
        p.center(); p.orderFrontRegardless(); hintWindow = p
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
