import Foundation
import IOKit

let german = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
func L(_ de: String, _ en: String) -> String { german ? de : en }

struct Cable { var speed: String; var bps: Double; var watts: Int }
/// Negotiated charging contract (USB-PD) and the charger's total power offering.
struct Charger { var watts: Int; var volts: Double; var maxWatts: Int; var pd: Bool }
struct Device: Equatable { var name: String; var bps: Double; var volumes: [String]; var loc: UInt32 }
struct PortState {
    var number: Int
    var active = false
    var uuid = ""
    var location = ""   // e.g. left-back, left-front, right; empty = unknown
    var magsafe = false
    /// SD slot: bus speed of the negotiated card mode in MB/s and the mode itself (e.g. SDR104).
    var sdMBs: Double?
    /// Thunderbolt: negotiated link speed to the first device and its name.
    var tbBps: Double?
    var tbName = ""
    var sdMode = ""
    var place: String {
        if magsafe { return "MagSafe" }
        if sdMBs != nil || location == "sd" { return L("SD-Karte", "SD card") }
        if location.isEmpty { return "Port \(number)" }
        let t = ["left": "links", "right": "rechts", "back": "hinten", "front": "vorne", "middle": "Mitte"]
        let s = location.split(separator: "-").map { german ? (t[String($0)] ?? String($0)) : String($0) }.joined(separator: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    var transports: [String] = []
    var cable: Cable?
    var charger: Charger?
    var devices: [Device] = []
    var chargeText: String? {
        charger.map { c in
            let v = c.volts.rounded() == c.volts ? "\(Int(c.volts)) V" : String(format: "%.1f V", c.volts)
            return "\(c.watts) W · \(v)"
        }
    }

    var isThunderbolt: Bool { transports.contains("CIO") }
    /// The fastest device connected directly to the port counts; hubs often have slower peripherals behind them.
    var main: Device? {
        let storage = devices.filter { !$0.volumes.isEmpty }
        return (storage.isEmpty ? devices : storage).min { a, b in
            storage.isEmpty ? a.bps > b.bps : a.bps < b.bps
        }
    }
    var slowStorage: Bool { sdMBs == nil && (main.map { !$0.volumes.isEmpty && $0.bps < 1e9 }) ?? false }
    var speedText: String? {
        if let s = sdMBs { return "\(Int(s.rounded())) MB/s" }
        if let m = main { return Self.fmt(m.bps) }
        if isThunderbolt { return tbBps.map(Self.fmt) ?? "Thunderbolt" }
        if let c = charger { return "\(c.watts) W" }
        return nil
    }
    static func fmt(_ bps: Double) -> String {
        bps >= 1e9 ? "\(Int((bps / 1e9).rounded())) Gb/s" : "\(Int((bps / 1e6).rounded())) Mb/s"
    }
    /// Approximate maximum speeds in MB/s after protocol overhead.
    static func realMBs(_ bps: Double) -> Double {
        switch bps { case 2e10...: return 2000; case 1e10...: return 1000; case 5e9...: return 430
        case 4e8...: return 40; default: return bps / 8e6 * 0.7 }
    }
    static func copyTime(_ bps: Double) -> String { duration(100_000 / realMBs(bps)) }
    static func duration(_ s: Double) -> String {
        return s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int((s / 60).rounded())) min" : String(format: "%.1f h", s / 3600)
    }
    var detail: String {
        // SD: bus limit minus about 10% for protocol overhead; the card itself may be slower.
        if let s = sdMBs, let m = main {
            let who = m.volumes.isEmpty ? m.name : m.volumes.joined(separator: ", ")
            return L("SD-Karte · \(who) · 100 GB ab \(Self.duration(100_000 / (s * 0.9)))", "SD card · \(who) · 100 GB in about \(Self.duration(100_000 / (s * 0.9)))")
        }
        if let m = main {
            let who = m.volumes.isEmpty ? m.name : m.volumes.joined(separator: ", ")
            let s = m.volumes.isEmpty ? who : L("\(who) · 100 GB ab \(Self.copyTime(m.bps))", "\(who) · 100 GB in about \(Self.copyTime(m.bps))")
            return charger.map { s + L(" · lädt mit \($0.watts) W", " · charging at \($0.watts) W") } ?? s
        }
        if isThunderbolt, tbBps != nil { return "Thunderbolt" + (tbName.isEmpty ? "" : " · \(tbName)") + (charger.map { L(" · lädt mit \($0.watts) W", " · charging at \($0.watts) W") } ?? "") }
        if isThunderbolt { return L("Thunderbolt / USB4 verbunden", "Thunderbolt / USB4 connected") + (charger.map { L(" · lädt mit \($0.watts) W", " · charging at \($0.watts) W") } ?? "") }
        // As with devices, show only the name; voltage and the charger's maximum are in the menu.
        // MagSafe is only the cable; behind it is a regular USB-C charger, either PD or a slower one.
        if let c = charger {
            let kind = c.pd ? L("PD-Netzteil", "PD charger") : L("Langsames Netzteil", "Slow charger")
            return magsafe ? "MagSafe · " + kind : kind
        }
        if let c = cable { return L("Nur Kabel oder Strom · Kabel bis \(c.speed)", "Cable or power only · cable up to \(c.speed)") }
        return L("Kein Datengerät erkannt", "No data device detected")
    }
    var verdict: String? {
        guard slowStorage, let m = main else { return nil }
        if let c = cable, c.bps <= m.bps { return L("Das Kabel kann nur USB 2", "This cable is USB 2 only") }
        if let c = cable, c.bps > 1e9 { return L("Kabel kann mehr. Stecker oder Gerät prüfen", "Cable can do more. Check plug or device") }
        return L("Bremse: Kabel, Stecker oder Gerät", "Bottleneck: cable, plug or device")
    }
}

enum Hardware {
    static let magsafeBase = 100
    static func prop(_ e: io_registry_entry_t, _ k: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    static func each(_ cls: String, _ f: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let e = IOIteratorNext(it), e != 0 { f(e); IOObjectRelease(e) }
    }
    static func decode(_ vdos: [Data], type: Int) -> Cable? {
        guard vdos.count > 3, type == 3 || type == 4, vdos[3].count >= 4 else { return nil }
        let v = vdos[3].prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let speeds: [(String, Double)] = [("480 Mb/s", 4.8e8), ("5 Gb/s", 5e9), ("10 Gb/s (USB4: 20)", 1e10), ("40 Gb/s", 4e10), ("80 Gb/s", 8e10)]
        let i = Int(v & 7); guard i < speeds.count else { return nil }
        let amps = (v >> 5) & 3 == 2 ? 5 : 3
        let maxV = (v >> 9) & 3
        return Cable(speed: speeds[i].0, bps: speeds[i].1, watts: amps == 5 && maxV == 3 ? 240 : amps * 20)
    }
    static func mounts() -> [String: String] {
        var p: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&p, MNT_NOWAIT)
        var r: [String: String] = [:]
        for i in 0..<Int(n) {
            var s = p![i]
            let from = withUnsafeBytes(of: &s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if on.hasPrefix("/Volumes/") { r[(from as NSString).lastPathComponent] = (on as NSString).lastPathComponent }
        }
        return r
    }
    /// Only drives under this device; deeper USB devices (hubs) count as devices themselves.
    static func volumes(_ e: io_registry_entry_t, _ m: [String: String]) -> [String] {
        var out: [String] = []
        func walk(_ e: io_registry_entry_t) {
            var it: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(e, kIOServicePlane, &it) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(it) }
            while case let c = IOIteratorNext(it), c != 0 {
                if IOObjectConformsTo(c, "IOUSBHostDevice") == 0 {
                    if IOObjectConformsTo(c, "IOMedia") != 0, let b = prop(c, "BSD Name") as? String, let v = m[b], !out.contains(v) { out.append(v) }
                    walk(c)
                }
                IOObjectRelease(c)
            }
        }
        walk(e); return out
    }
    /// Apple stores the enclosure position in the port's parent node.
    static func location(_ e: io_registry_entry_t) -> String {
        let o = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let d = IORegistryEntrySearchCFProperty(e, kIOServicePlane, "port-location" as CFString, kCFAllocatorDefault, o) as? Data else { return "" }
        return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self).lowercased()
    }
    static let sdBase = 200
    /// Built-in SD slot. Old card values remain when no card is present, so read only while connected.
    static func sd(_ e: io_registry_entry_t, _ ports: inout [Int: PortState]) {
        let n = sdBase + ((prop(e, "PortNumber") as? NSNumber)?.intValue ?? 1)
        var p = PortState(number: n)
        p.location = "sd"
        p.active = (prop(e, "ConnectionActive") as? Bool ?? false) && (prop(e, "Card Present") as? Bool ?? false)
        p.uuid = prop(e, "ConnectionUUID") as? String ?? ""
        if p.active, let mhz = (prop(e, "Calculated Clock Frequency (MHz)") as? NSNumber)?.doubleValue, mhz > 0 {
            let width = (prop(e, "Bus Width") as? NSNumber)?.doubleValue ?? 4
            let mode = (prop(e, "Speed Mode") as? String ?? "").replacingOccurrences(of: "UHS: ", with: "")
            // MB/s = clock × data lines / 8; DDR transfers data twice per clock.
            let mbs = mhz * width / 8 * (mode.contains("DDR") ? 2 : 1)
            let info = prop(e, "Card Characteristics") as? [String: Any]
            let name = (info?["Product Name"] as? String).map { "SD \($0)" } ?? L("SD-Karte", "SD card")
            p.sdMBs = mbs; p.sdMode = mode
            p.devices = [Device(name: name, bps: mbs * 8e6, volumes: volumes(e, mounts()), loc: 0)]
        }
        ports[n] = p
    }
    /// Thunderbolt speed per port. Device switches (Depth 1) exist only when a device is connected;
    /// their upstream port knows the negotiated speed. Encoding follows the USB4 specification:
    /// Current Link Speed 0x8 = 10, 0x4 = 20, 0x2 = 40 Gb/s per lane; Width 2 = two lanes bonded.
    /// Not verified on real hardware (26.11.2026): unknown values fall back to "Thunderbolt".
    static func thunderbolt() -> [(socket: Int?, bps: Double, name: String)] {
        var r: [(socket: Int?, bps: Double, name: String)] = []
        each("IOThunderboltSwitch") { sw in
            guard (prop(sw, "Depth") as? NSNumber)?.intValue == 1,
                  let up = (prop(sw, "Upstream Port Number") as? NSNumber)?.intValue else { return }
            var it: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(sw, kIOServicePlane, &it) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(it) }
            while case let c = IOIteratorNext(it), c != 0 {
                defer { IOObjectRelease(c) }
                guard IOObjectConformsTo(c, "IOThunderboltPort") != 0, (prop(c, "Port Number") as? NSNumber)?.intValue == up,
                      let sp = (prop(c, "Current Link Speed") as? NSNumber)?.intValue,
                      let w = (prop(c, "Current Link Width") as? NSNumber)?.intValue, w == 1 || w == 2 else { continue }
                let lane: Double = [0x8: 10e9, 0x4: 20e9, 0x2: 40e9][sp] ?? 0
                guard lane > 0 else { continue }
                let o = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                let socket = (IORegistryEntrySearchCFProperty(sw, kIOServicePlane, "Socket ID" as CFString, kCFAllocatorDefault, o) as? String).flatMap { Int($0) }
                let name = [prop(sw, "Device Vendor Name") as? String, prop(sw, "Device Model Name") as? String].compactMap { $0 }.joined(separator: " ")
                r.append((socket, lane * Double(w), name))
            }
        }
        return r
    }
    static func scan() -> [PortState] {
        var ports: [Int: PortState] = [:]
        each("IOPort") { e in
            if let d = prop(e, "Description") as? String, d.hasPrefix("Port-SD") { sd(e, &ports); return }
            guard let d = prop(e, "Description") as? String, d.hasPrefix("Port-USB-C@") || d.hasPrefix("Port-MagSafe"),
                  let n = (prop(e, "PortNumber") as? NSNumber)?.intValue else { return }
            // MagSafe numbers start at 1; use a separate range to avoid collisions with USB-C.
            let mag = d.hasPrefix("Port-MagSafe")
            var p = PortState(number: mag ? magsafeBase + n : n)
            p.magsafe = mag
            p.active = prop(e, "ConnectionActive") as? Bool ?? false
            p.uuid = prop(e, "ConnectionUUID") as? String ?? ""
            p.transports = prop(e, "TransportsActive") as? [String] ?? []
            // MagSafe has no port-location; it is always at the far back on the left.
            p.location = mag ? "magsafe" : location(e)
            ports[p.number] = p
        }
        each("IOPortTransportComponentCCUSBPDSOPp") { e in
            guard (prop(e, "ParentPortTypeDescription") as? String) == "USB-C",
                  let n = (prop(e, "ParentPortNumber") as? NSNumber)?.intValue,
                  let md = prop(e, "Metadata") as? [String: Any], let v = md["VDOs"] as? [Data] else { return }
            ports[n]?.cable = decode(v, type: (md["Product Type"] as? NSNumber)?.intValue ?? 0)
        }
        // Charging power: count only sources with a negotiated contract; the highest wins.
        each("IOPortFeaturePowerSource") { e in
            let type = prop(e, "ParentPortTypeDescription") as? String ?? ""
            guard type == "USB-C" || type.hasPrefix("MagSafe"),
                  let pn = (prop(e, "ParentPortNumber") as? NSNumber)?.intValue,
                  let win = prop(e, "WinningPowerSourceOption") as? [String: Any],
                  let mw = (win["Max Power (mW)"] as? NSNumber)?.intValue, mw > 0 else { return }
            let n = type.hasPrefix("MagSafe") ? magsafeBase + pn : pn
            let mv = (win["Voltage (mV)"] as? NSNumber)?.doubleValue ?? 0
            let opts = prop(e, "PowerSourceOptions") as? [[String: Any]] ?? []
            let best = opts.compactMap { ($0["Max Power (mW)"] as? NSNumber)?.intValue }.max() ?? mw
            let c = Charger(watts: Int((Double(mw) / 1000).rounded()), volts: (mv / 100).rounded() / 10, maxWatts: Int((Double(max(best, mw)) / 1000).rounded()),
                            pd: (prop(e, "PowerSourceName") as? String) == "USB-PD")
            // The last contract remains after unplugging, so only use it while the port is active.
            if ports[n]?.active == true, (ports[n]?.charger?.watts ?? 0) < c.watts { ports[n]?.charger = c }
        }
        var bus: [UInt32: Int] = [:]
        each("AppleUSBHostPort") { e in
            guard let l = (prop(e, "locationID") as? NSNumber)?.uint32Value else { return }
            if let d = prop(e, "usb-c-port-number") as? Data, let n = d.first { bus[l >> 24] = Int(n); return }
            // Newer Macs (e.g. Mac17,9) lack this value but provide the path to the port: …/Port-USB-C@2
            if let path = prop(e, "UsbIOPort") as? String, let r = path.range(of: "/Port-USB-C@", options: .backwards),
               let n = Int(path[r.upperBound...]) { bus[l >> 24] = n }
        }
        let m = mounts()
        each("IOUSBHostDevice") { e in
            guard let l = (prop(e, "locationID") as? NSNumber)?.uint32Value, let n = bus[l >> 24],
                  let s = (prop(e, "UsbLinkSpeed") as? NSNumber)?.doubleValue else { return }
            let name = prop(e, "USB Product Name") as? String ?? L("USB-Gerät", "USB device")
            ports[n]?.devices.append(Device(name: name, bps: s, volumes: volumes(e, m), loc: l))
        }
        // One Thunderbolt device: unambiguous. For multiple devices, assign only by socket number.
        let tb = thunderbolt(), tbPorts = ports.values.filter { $0.isThunderbolt }.map(\.number)
        for t in tb {
            guard let n = tb.count == 1 && tbPorts.count == 1 ? tbPorts.first : t.socket.flatMap({ tbPorts.contains($0) ? $0 : nil }) else { continue }
            ports[n]?.tbBps = t.bps; ports[n]?.tbName = t.name
        }
        // MagSafe first: it is at the far back on the left, before the USB-C ports.
        return ports.values.sorted { ($0.magsafe ? 0 : 1, $0.number) < ($1.magsafe ? 0 : 1, $1.number) }
    }
}
