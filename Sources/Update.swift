import AppKit
import CryptoKit

/// Automatic updates: checks GitHub daily, downloads only newer versions, and installs only
/// versions signed with Diego's key. The private key is not on GitHub.
/// No information about the Mac is sent.
@MainActor enum Update {
    static let publicKey = "IS1P7wj/2w/SZ55SbBeegivm7FrkMBk4viDslSfdgRc="
    #if TESTFEED
    static let base = ProcessInfo.processInfo.environment["FEED"]!
    #else
    static let base = "https://github.com/diegobruegger-prog/cablepeek/releases/latest/download"
    #endif
    static let page = URL(string: "https://github.com/diegobruegger-prog/cablepeek/releases/latest")!
    struct Feed: Decodable { var version: String; var sig: String }
    struct Failed: Error { var why: String; init(_ w: String) { why = w } }

    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "noAutoUpdate") }
        set { UserDefaults.standard.set(!newValue, forKey: "noAutoUpdate") }
    }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static func newer(_ a: String, than b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }
    private static var running = false

    static func start(idle: @escaping @MainActor () -> Bool) {
        func go() { if enabled { Task { try? await run(idle: idle) } } }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in MainActor.assumeIsolated { go() } }
        let t = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in MainActor.assumeIsolated { go() } }
        t.tolerance = 3600
    }
    /// true = new version installed (app restarts), false = already up to date.
    @discardableResult static func run(idle: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard !running else { return false }
        running = true; defer { running = false }
        let net = URLSession(configuration: .ephemeral); defer { net.finishTasksAndInvalidate() }
        let feed = try JSONDecoder().decode(Feed.self, from: try await get(net, "update.json", limit: 10_000))
        guard newer(feed.version, than: current) else { return false }

        let app = Bundle.main.bundleURL, fm = FileManager.default
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: app.deletingLastPathComponent().path), fm.isWritableFile(atPath: app.path) else { throw Failed("location") }

        let zip = try await get(net, "CablePeek-update.zip", limit: 50_000_000)
        guard let k = Data(base64Encoded: publicKey), let s = Data(base64Encoded: feed.sig),
              try Curve25519.Signing.PublicKey(rawRepresentation: k).isValidSignature(s, for: zip) else { throw Failed("signature") }

        let tmp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("u.zip"); try zip.write(to: file)
        try await tool("/usr/bin/ditto", ["-x", "-k", file.path, tmp.path])
        let new = tmp.appendingPathComponent("CablePeek.app")
        try await tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path])
        // Read the identifier and version from the signed bundle to prevent anyone from substituting an old version.
        guard let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = info["CFBundleShortVersionString"] as? String, v == feed.version, newer(v, than: current) else { throw Failed("content") }

        // Never during an ejection or while someone is using the card.
        while !idle() { try await Task.sleep(nanoseconds: 2_000_000_000) }
        _ = try fm.replaceItemAt(app, withItemAt: new)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; exec /usr/bin/open \"$0\"", app.path]
        try p.run()
        NSApp.terminate(nil)
        return true
    }
    private static func get(_ net: URLSession, _ name: String, limit: Int) async throws -> Data {
        let (d, r) = try await net.data(from: URL(string: base + "/" + name)!)
        guard (r as? HTTPURLResponse)?.statusCode == 200, d.count <= limit else { throw Failed("download") }
        return d
    }
    private static func tool(_ path: String, _ args: [String]) async throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { q in q.terminationStatus == 0 ? c.resume() : c.resume(throwing: Failed(path)) }
            do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
        }
    }
}
