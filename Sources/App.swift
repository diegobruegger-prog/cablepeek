import SwiftUI
import AppKit
import IOKit
import ServiceManagement

struct Card: View {
    let p: PortState; let settled: Bool; let left: Bool
    var interactive = false
    @State private var state = ""   // "", busy, ok, fail
    var volumes: [String] { p.devices.flatMap(\.volumes) }
    func eject() {
        state = "busy"; Eject.busy += 1
        Eject.run(volumes) { Eject.busy -= 1; state = $0 ? "ok" : "fail" }
    }
    @ViewBuilder var ejectPart: some View {
        if state == "busy" { ProgressView().controlSize(.small).frame(width: 28) }
        else if state == "ok" { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).frame(width: 28) }
        else {
            Button(action: eject) {
                Image(systemName: "eject.fill").font(.system(size: 12)).frame(width: 28, height: 28)
                    .background(Circle().fill(.primary.opacity(0.1))).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("Auswerfen: ", "Eject: ") + volumes.joined(separator: ", "))
            .accessibilityLabel(L("Auswerfen", "Eject"))
        }
    }
    var line: String {
        switch state {
        case "busy": return L("Wird ausgeworfen …", "Ejecting …")
        case "ok": return L("Ausgeworfen, Kabel kann raus", "Ejected, safe to unplug")
        case "fail": return L("In Gebrauch, nicht ausgeworfen", "In use, not ejected")
        default: return p.verdict ?? p.detail
        }
    }
    /// Charger without USB-PD: same lightning bolt, just orange.
    var slowCharge: Bool { p.main == nil && !p.isThunderbolt && p.charger?.pd == false }
    var color: Color { p.slowStorage || slowCharge ? .orange : (p.speedText == nil ? .secondary : .green) }
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: p.sdMBs != nil ? "sdcard.fill" : p.slowStorage ? "exclamationmark" : (p.speedText == nil ? "cable.connector" : "bolt.fill"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.speedText ?? (settled ? L("Keine Daten", "No data") : L("Erkenne …", "Detecting …")))
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                if settled || p.speedText != nil {
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if p.verdict != nil && state.isEmpty { Text(p.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if interactive && !volumes.isEmpty { ejectPart }
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .modifier(Glass())
        .fixedSize()
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .leading : .trailing)
    }
}
/// Small glass indicator on the edge: shows where you can hover. Clicks pass through.
struct Hint: View {
    var body: some View {
        Group {
            if #available(macOS 26, *) { Capsule().fill(.white.opacity(0.08)).glassEffect(.regular, in: .capsule) }
            else { Capsule().fill(.ultraThinMaterial) }
        }
        // Outlined in light and dark so it stays visible on any background.
        .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.5).padding(0.5))
        .overlay(Capsule().strokeBorder(.black.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 1.5)
        .frame(width: 6, height: 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
/// First click takes effect immediately without bringing the app to the foreground.
final class CardHost: NSHostingView<Card> { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }
struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular, in: .rect(cornerRadius: 20)) }
        else { content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)) }
    }
}

@MainActor final class Overlay {
    private var panels: [Int: NSPanel] = [:]
    private var timers: [Int: Timer] = [:]
    private var hints: [Int: NSPanel] = [:]
    static var hintsOn: Bool {
        get { UserDefaults.standard.object(forKey: "edgeHints") as? Bool ?? true }   // Default: on
        set { UserDefaults.standard.set(newValue, forKey: "edgeHints") }
    }
    /// Hint for each occupied port when its card is not open.
    func syncHints(_ ports: [PortState]) {
        var want: Set<Int> = []
        for p in ports where Self.hintsOn && p.active && panels[p.number] == nil {
            guard let f = Self.frame(p), let s = Self.screen() else { continue }
            want.insert(p.number)
            let r = NSRect(x: Self.left(p) ? s.frame.minX : s.frame.maxX - 14, y: f.midY - 26, width: 14, height: 52)
            let w = hints[p.number] ?? {
                let w = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
                w.level = .statusBar; w.ignoresMouseEvents = true; w.hidesOnDeactivate = false
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                w.contentView = NSHostingView(rootView: Hint())
                hints[p.number] = w; return w
            }()
            if w.frame != r { w.setFrame(r, display: true) }
            w.orderFrontRegardless()
        }
        for (n, w) in hints where !want.contains(n) { w.orderOut(nil); hints[n] = nil }
    }
    static func screen() -> NSScreen? {
        NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) != 0
        } ?? NSScreen.main
    }
    static let size = NSSize(width: 420, height: 100)
    static func left(_ p: PortState) -> Bool { !p.location.hasPrefix("right") && p.location != "sd" }
    static func frame(_ p: PortState) -> NSRect? {
        guard let s = screen() else { return nil }
        let l = p.location
        // The ports are at the back of the case, so at the bottom of the screen near the hinge.
        // If the location is unknown, stack by number to avoid overlap.
        // The SD slot is at the front right, so lower than the right USB-C port.
        let dy: CGFloat = l == "sd" ? 20 : l == "magsafe" ? 230 : l.hasSuffix("back") ? 150 : l.hasSuffix("front") ? 70 : l == "left" || l == "right" ? 110 : 70 + 80 * CGFloat(p.number - 1)
        return NSRect(origin: NSPoint(x: left(p) ? s.frame.minX : s.frame.maxX - size.width, y: s.frame.minY + dy), size: size)
    }
    /// Narrow strip along the edge that reveals the display.
    static func edge(_ p: PortState) -> NSRect? {
        guard let f = frame(p) else { return nil }
        return NSRect(x: left(p) ? f.minX - 1 : f.maxX - 5, y: f.midY - 35, width: 6, height: 70)
    }
    /// Visible card (excluding the empty part of the window).
    func card(_ p: PortState) -> NSRect? {
        guard let f = Self.frame(p), let w = panels[p.number] else { return nil }
        let cw = min(f.width, (w.contentView as? NSHostingView<Card>).map { $0.fittingSize.width } ?? 300)
        return NSRect(x: Self.left(p) ? f.minX - 1 : f.maxX - cw, y: f.midY - 40, width: cw + 1, height: 80)
    }
    func visible(_ n: Int) -> Bool { panels[n] != nil }
    func hideSoon(_ n: Int, _ t: Double) {
        timers[n]?.invalidate()
        timers[n] = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in MainActor.assumeIsolated { self.hide(n) } }
    }
    func show(_ p: PortState, settled: Bool, seconds: Double = 4, interactive: Bool = false) {
        guard let target = Self.frame(p) else { return }
        let left = Self.left(p), size = Self.size
        let end = target.origin
        let fresh = panels[p.number] == nil
        let w = panels[p.number] ?? {
            let w = NSPanel(contentRect: NSRect(origin: end, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.level = .statusBar; w.ignoresMouseEvents = true; w.hidesOnDeactivate = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panels[p.number] = w; return w
        }()
        // Clickable only while hovered (eject); otherwise clicks pass through.
        w.ignoresMouseEvents = !interactive
        w.contentView = CardHost(rootView: Card(p: p, settled: settled, left: left, interactive: interactive))
        if fresh {
            w.setFrame(NSRect(origin: NSPoint(x: end.x + (left ? -24 : 24), y: end.y), size: size), display: true)
            w.alphaValue = 0
        }
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.3; c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
            w.animator().setFrame(NSRect(origin: end, size: size), display: true)
        }
        timers[p.number]?.invalidate()
        let n = p.number
        timers[n] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { self.hide(n) }
        }
    }
    func hide(_ n: Int) {
        timers[n]?.invalidate()
        guard let w = panels.removeValue(forKey: n) else { return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.35; w.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { w.orderOut(nil) } })
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let overlay = Overlay()
    var ports: [PortState] = []
    var connectedAt: [Int: Date] = [:]
    var shown: [Int: String] = [:]
    var pending = false
    var notify: IONotificationPortRef?
    var iters: [io_iterator_t] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        ports = Hardware.scan(); icon()
        listen()
        // Tracks only the mouse position; does not intercept events.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouse(NSEvent.mouseLocation) }
        }
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
        t.tolerance = 0.3; RunLoop.main.add(t, forMode: .common)
        Update.start { [weak self] in self?.held.isEmpty ?? true && Eject.busy == 0 }
        if CommandLine.arguments.contains("--demo") { showAll() }
        if CommandLine.arguments.contains("--demo-hover") { for p in ports where p.active { overlay.show(p, settled: true, seconds: 8, interactive: true) } }
    }
    func listen() {
        notify = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notify!).takeUnretainedValue(), .commonModes)
        let cb: IOServiceMatchingCallback = { ctx, it in
            while case let e = IOIteratorNext(it), e != 0 { IOObjectRelease(e) }
            MainActor.assumeIsolated { Unmanaged<Delegate>.fromOpaque(ctx!).takeUnretainedValue().soon() }
        }
        for c in ["IOUSBHostDevice", "IOPortTransportComponentCCUSBPDSOPp", "IOPortTransportState", "IOPortFeaturePowerSource"] {
            for k in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var it: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(notify, k, IOServiceMatching(c), cb, Unmanaged.passUnretained(self).toOpaque(), &it) == KERN_SUCCESS else { continue }
                while case let e = IOIteratorNext(it), e != 0 { IOObjectRelease(e) }
                iters.append(it)
            }
        }
    }
    func soon() {
        if pending { return }; pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { self.pending = false; self.refresh() } }
    }
    func refresh() {
        let now = Hardware.scan()
        for var p in now {
            let old = ports.first { $0.number == p.number }
            if !p.active { if connectedAt.removeValue(forKey: p.number) != nil || old?.active == true { overlay.hide(p.number); shown[p.number] = nil; held.remove(p.number) }; continue }
            if old?.active != true || old?.uuid != p.uuid { connectedAt[p.number] = Date(); shown[p.number] = nil }
            // Keep updating for 8 s after plugging in, then only in the menu.
            guard let t = connectedAt[p.number] else { continue }
            let age = Date().timeIntervalSince(t)
            let settled = age > 3
            // Type-C is briefly selected first (5 V, 15 W); USB-PD follows after ~0.5 s. Don't show it until then;
            // pure 5 V chargers still appear after the settling period.
            if !settled, p.charger?.pd == false { p.charger = nil }
            let key = "\(p.speedText ?? "")|\(p.verdict ?? "")|\(p.detail)|\(settled || p.speedText != nil)"
            if shown[p.number] != key, !held.contains(p.number) { shown[p.number] = key; overlay.show(p, settled: settled) }
            if age > 8 { connectedAt[p.number] = nil }
        }
        ports = now; icon(); overlay.syncHints(ports)
    }
    func icon() {
        let slow = ports.contains { $0.active && $0.slowStorage }
        // Custom icon: USB-C port. Slow = small dot, not a warning triangle.
        let img = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let port = NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 17, height: 8), xRadius: 4, yRadius: 4)
            port.lineWidth = 1.5; port.stroke()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 7.1, width: 9, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
            if slow { NSBezierPath(ovalIn: NSRect(x: 19, y: 10.5, width: 4.5, height: 4.5)).fill() }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = slow ? L("CablePeek: langsame Verbindung", "CablePeek: slow connection") : "CablePeek"
        item.button?.image = img
    }
    var dwell: (port: Int, timer: Timer)?
    var held: Set<Int> = []
    var poll: Timer?
    func mouse(_ m: NSPoint) {
        var over: Int?
        for p in ports where p.active {
            let n = p.number
            if overlay.visible(n), overlay.card(p)?.contains(m) == true {
                if !held.contains(n) { held.insert(n); overlay.show(p, settled: true, seconds: 600, interactive: true) } else { overlay.hideSoon(n, 600) }
            } else if held.remove(n) != nil, overlay.visible(n) { overlay.hideSoon(n, 0.4) }
            if !overlay.visible(n), Overlay.edge(p)?.contains(m) == true { over = n }
        }
        overlay.syncHints(ports)
        if held.isEmpty { poll?.invalidate(); poll = nil }
        else if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                MainActor.assumeIsolated { self.mouse(NSEvent.mouseLocation) }
            }
        }
        if over == dwell?.port { return }
        dwell?.timer.invalidate(); dwell = nil
        guard let n = over else { return }
        // Wait briefly so simply passing by doesn't trigger anything.
        dwell = (n, Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.dwell = nil
                guard let p = Hardware.scan().first(where: { $0.number == n && $0.active }),
                      Overlay.edge(p)?.contains(NSEvent.mouseLocation) == true else { return }
                self.held.insert(n)
                self.overlay.show(p, settled: true, seconds: 600, interactive: true)
                self.mouse(NSEvent.mouseLocation)
            }
        })
    }
    @objc func showAll() { for p in Hardware.scan() where p.active { overlay.show(p, settled: true, seconds: 8) } }
    @objc func edgeHints() { Overlay.hintsOn.toggle(); overlay.syncHints(ports) }
    @objc func login() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { NSAlert(error: error).runModal() }
    }
    @objc func coffee() { NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/diegoespresso")!) }
    @objc func autoUpdate() { Update.enabled.toggle() }
    @objc func updates() {
        Task {
            let a = NSAlert()
            do {
                if try await Update.run(idle: { self.held.isEmpty && Eject.busy == 0 }) { return }
                a.messageText = L("CablePeek \(Update.current) ist aktuell.", "CablePeek \(Update.current) is up to date.")
            } catch {
                a.messageText = L("Update nicht möglich.", "Could not update.")
                a.informativeText = L("Du kannst die neueste Version von der Website laden.", "You can get the latest version from the website.")
                a.addButton(withTitle: L("Seite öffnen", "Open page")); a.addButton(withTitle: L("Abbrechen", "Cancel"))
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Update.page) }
                return
            }
            NSApp.activate(ignoringOtherApps: true); a.runModal()
        }
    }
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        ports = Hardware.scan(); icon()
        for p in ports {
            let i = NSMenuItem(title: "\(p.place): \(p.active ? (p.speedText ?? L("keine Daten", "no data")) : L("frei", "empty"))", action: nil, keyEquivalent: "")
            if p.active {
                let sub = NSMenu()
                for d in p.devices { sub.addItem(withTitle: "\(d.name)\(d.volumes.isEmpty ? "" : " (\(d.volumes.joined(separator: ", ")))"): \(p.sdMBs != nil ? "\(p.speedText!) (\(p.sdMode))" : PortState.fmt(d.bps))", action: nil, keyEquivalent: "") }
                if let c = p.charger {
                    sub.addItem(withTitle: L("Laden", "Charging") + ": \(p.chargeText!)" + (c.maxWatts > c.watts ? L(", Netzteil bis \(c.maxWatts) W", ", charger up to \(c.maxWatts) W") : ""), action: nil, keyEquivalent: "")
                }
                if p.sdMBs == nil { sub.addItem(withTitle: p.cable.map { L("Kabelchip", "Cable chip") + ": \($0.speed), \($0.watts) W" } ?? L("Kein Kabelchip gefunden", "No cable chip found"), action: nil, keyEquivalent: "") }
                if let v = p.verdict { sub.addItem(withTitle: v, action: nil, keyEquivalent: "") }
                i.submenu = sub
            }
            m.addItem(i)
        }
        m.addItem(.separator())
        m.addItem(withTitle: L("Anzeigen", "Show now"), action: #selector(showAll), keyEquivalent: "").target = self
        let l = m.addItem(withTitle: L("Beim Anmelden starten", "Launch at login"), action: #selector(login), keyEquivalent: ""); l.target = self
        l.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let u = m.addItem(withTitle: L("Automatische Updates", "Automatic updates"), action: #selector(autoUpdate), keyEquivalent: ""); u.target = self
        u.state = Update.enabled ? .on : .off
        let h = m.addItem(withTitle: L("Markierung am Rand zeigen", "Show edge markers"), action: #selector(edgeHints), keyEquivalent: ""); h.target = self
        h.state = Overlay.hintsOn ? .on : .off
        m.addItem(withTitle: L("Nach Updates suchen (du hast \(Update.current))", "Check for updates (you have \(Update.current))"), action: #selector(updates), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Kaffee spendieren", "Buy me a coffee"), action: #selector(coffee), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Beenden", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

@main struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--dump") {
            for p in Hardware.scan() { print(p.place, Overlay.edge(p).map { "\(Int($0.midX)),\(Int($0.midY))" } ?? "-", p.active ? "aktiv" : "frei", p.speedText ?? "-", "|", p.detail, "|", p.verdict ?? "-", "|", p.cable.map { "\($0.speed) \($0.watts)W" } ?? "kein Chip", "|", p.charger.map { "\(p.chargeText!) (max \($0.maxWatts) W)" } ?? "kein Laden") }
            return
        }
        let d = Delegate(); NSApplication.shared.delegate = d
        NSApplication.shared.setActivationPolicy(.accessory)
        withExtendedLifetime(d) { NSApplication.shared.run() }
    }
}
