// Horizon bridge: plays a Bluetooth DualSense in Horizon (the Rust rewrite of Minecraft: Java
// Edition) through the game's control socket (`horizon-ctl pad ...`).
//
// Why: on macOS a Bluetooth DualSense ends up sending its full input report (0x31). macOS's own
// controller driver switches it there, and so does any output report, including Trigger Lab's.
// Horizon's controller library only reads the simple report, so the game sees the controller
// connected but none of its presses. Trigger Lab already reads the full report, so it passes
// the buttons, sticks and triggers on. Over USB Horizon reads the controller by itself and
// nothing is forwarded.

import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Controller state

/// Horizon's names for the buttons (`horizon-ctl pad <name> down|up`).
enum PadButton: String, CaseIterable {
    case south, east, west, north, lb, rb, select, start, ls, rs, up, down, left, right
}

/// One moment of the controller: sticks are [x, y] with right and up positive, -1...1;
/// triggers 0...1.
struct PadSnapshot: Equatable {
    var buttons: Set<PadButton> = []
    var left: [Double] = [0, 0]
    var right: [Double] = [0, 0]
    var triggers: [Double] = [0, 0]

    static let neutral = PadSnapshot()
}

// MARK: - DualSense report parsing

enum DualSense {
    static let vendorID = 0x054C
    static let productIDs = [0x0CE6, 0x0DF2]  // DualSense, DualSense Edge

    /// The full Bluetooth input report. macOS's own controller driver switches a Bluetooth
    /// DualSense to it, and Horizon can't read it: this is the report the bridge forwards.
    static let bluetoothFullReportID: UInt8 = 0x31

    /// Parses a Bluetooth full input report (report ID 0x31 as byte 0, then a sequence/tag byte,
    /// then the common DualSense input block, as in Linux's hid-playstation). Any other report
    /// gives nil: the simple report 0x01 and USB reports are ones Horizon reads by itself.
    static func parse(_ report: [UInt8]) -> PadSnapshot? {
        guard report.count >= 12, report[0] == bluetoothFullReportID else { return nil }
        let d = 2  // the block starts after the report ID and the sequence byte
        let lx = report[d], ly = report[d + 1], rx = report[d + 2], ry = report[d + 3]
        let l2 = report[d + 4], r2 = report[d + 5]
        let b0 = report[d + 7], b1 = report[d + 8]

        var s = PadSnapshot()
        s.left = stick(lx, ly)
        s.right = stick(rx, ry)
        s.triggers = [trigger(l2), trigger(r2)]

        // Face buttons: square, cross, circle, triangle in bits 4...7 of the first byte.
        if b0 & 0x10 != 0 { s.buttons.insert(.west) }
        if b0 & 0x20 != 0 { s.buttons.insert(.south) }
        if b0 & 0x40 != 0 { s.buttons.insert(.east) }
        if b0 & 0x80 != 0 { s.buttons.insert(.north) }
        // D-pad: a hat in the low nibble, 0 = up, clockwise, 8 = released.
        switch b0 & 0x0F {
        case 0: s.buttons.insert(.up)
        case 1: s.buttons.formUnion([.up, .right])
        case 2: s.buttons.insert(.right)
        case 3: s.buttons.formUnion([.down, .right])
        case 4: s.buttons.insert(.down)
        case 5: s.buttons.formUnion([.down, .left])
        case 6: s.buttons.insert(.left)
        case 7: s.buttons.formUnion([.up, .left])
        default: break
        }
        // Second byte: L1, R1, L2 (digital), R2 (digital), Create, Options, L3, R3.
        // L2/R2 go through the analog triggers, as Horizon reads them.
        if b1 & 0x01 != 0 { s.buttons.insert(.lb) }
        if b1 & 0x02 != 0 { s.buttons.insert(.rb) }
        if b1 & 0x10 != 0 { s.buttons.insert(.select) }
        if b1 & 0x20 != 0 { s.buttons.insert(.start) }
        if b1 & 0x40 != 0 { s.buttons.insert(.ls) }
        if b1 & 0x80 != 0 { s.buttons.insert(.rs) }
        return s
    }

    /// A stick byte pair to [x, y], up positive. Values this close to the centre are sent as 0, so
    /// a resting stick's drift never keeps Horizon's virtual pad "in use"; Horizon applies its
    /// own deadzones on top.
    static func stick(_ x: UInt8, _ y: UInt8) -> [Double] {
        // 128 is the centre; 0 and 255 are full tilt.
        func axis(_ v: UInt8) -> Double {
            let c = Double(v) - 128
            return max(-1, min(1, c >= 0 ? c / 127 : c / 128))
        }
        let fx = axis(x)
        let fy = -axis(y)
        if (fx * fx + fy * fy).squareRoot() < 0.10 { return [0, 0] }
        return [round3(fx), round3(fy)]
    }

    static func trigger(_ v: UInt8) -> Double {
        let f = Double(v) / 255
        return f < 0.02 ? 0 : round3(f)
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

// MARK: - Commands for Horizon

enum Commands {
    static func button(_ b: PadButton, _ down: Bool) -> String {
        "pad \(b.rawValue) \(down ? "down" : "up")"
    }
    static func stick(_ side: String, _ v: [Double]) -> String {
        "pad stick \(side) \(fmt(v[0])) \(fmt(v[1]))"
    }
    static func trigger(_ side: String, _ v: Double) -> String {
        "pad trigger \(side) \(fmt(v))"
    }
    static func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

    /// What changed between two snapshots, as commands: button edges in order, then the sticks
    /// and triggers that moved by more than `epsilon` (or came back to exactly 0).
    static func diff(from old: PadSnapshot, to new: PadSnapshot, epsilon: Double = 0.01)
        -> (buttons: [String], left: String?, right: String?, lt: String?, rt: String?)
    {
        var buttons: [String] = []
        for b in PadButton.allCases {
            let was = old.buttons.contains(b), now = new.buttons.contains(b)
            if was != now { buttons.append(button(b, now)) }
        }
        func moved(_ a: [Double], _ b: [Double]) -> Bool {
            if a != b && b == [0, 0] { return true }
            return abs(a[0] - b[0]) > epsilon || abs(a[1] - b[1]) > epsilon
        }
        func movedT(_ a: Double, _ b: Double) -> Bool {
            if a != b && b == 0 { return true }
            return abs(a - b) > epsilon
        }
        return (
            buttons,
            moved(old.left, new.left) ? stick("left", new.left) : nil,
            moved(old.right, new.right) ? stick("right", new.right) : nil,
            movedT(old.triggers[0], new.triggers[0]) ? trigger("left", new.triggers[0]) : nil,
            movedT(old.triggers[1], new.triggers[1]) ? trigger("right", new.triggers[1]) : nil
        )
    }
}

// MARK: - Horizon's control socket

/// Where the running game listens: `$HORIZON_CONTROL`, else `horizon-control.sock` in the user's
/// temporary folder (what Horizon uses on macOS, which has no `$XDG_RUNTIME_DIR`).
func horizonSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String
{
    if let p = environment["HORIZON_CONTROL"], !p.isEmpty { return p }
    if let d = environment["XDG_RUNTIME_DIR"], !d.isEmpty {
        return (d as NSString).appendingPathComponent("horizon-control.sock")
    }
    return (NSTemporaryDirectory() as NSString).appendingPathComponent("horizon-control.sock")
}

/// One connection to the game's control socket, on its own thread. The game answers one line
/// per command between two frames, so a connection carries one command per frame: the bridge
/// keeps one per stick and trigger (only the newest value matters, older ones are dropped) and
/// one for buttons (every press and release is kept, in order).
final class Channel {
    let name: String
    let path: String
    let coalesce: Bool
    /// Sent first on every new connection (the buttons channel says the pad is a PlayStation one).
    let greeting: [String]
    /// Checks every 2 s of quiet that the game is still there (one channel is enough).
    let keepalive: Bool

    private let cond = NSCondition()
    private var queue: [String] = []
    /// The newest value of a coalescing channel, sent again after a reconnect (a restarted game
    /// forgot it).
    private var latest: String?
    private var fd: Int32 = -1
    private var running = true

    private(set) var connected = false
    private(set) var lastError: String?
    var onStatusChange: (() -> Void)?

    init(
        name: String, path: String, coalesce: Bool, greeting: [String] = [],
        keepalive: Bool = false
    ) {
        self.name = name
        self.path = path
        self.coalesce = coalesce
        self.greeting = greeting
        self.keepalive = keepalive
        let t = Thread { [weak self] in self?.run() }
        t.name = "bridge-\(name)"
        t.start()
    }

    func send(_ line: String) {
        cond.lock()
        if coalesce {
            queue = [line]
            latest = line
        } else {
            queue.append(line)
            if queue.count > 64 { queue.removeFirst(queue.count - 64) }
        }
        cond.signal()
        cond.unlock()
    }

    func stop() {
        cond.lock()
        running = false
        cond.signal()
        cond.unlock()
    }

    private func run() {
        while true {
            cond.lock()
            var idle = false
            while queue.isEmpty && running && connected {
                if !cond.wait(until: Date().addingTimeInterval(2)) {
                    idle = true
                    break
                }
            }
            if idle && keepalive && queue.isEmpty {
                // Nothing to send for 2 s: a harmless `hello` shows whether the game is still there.
                cond.unlock()
                exchange("hello")
                continue
            }
            if !running {
                cond.unlock()
                closeSocket()
                return
            }
            cond.unlock()

            if !connected {
                if !connect() {
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                for g in greeting { _ = exchange(g) }
                cond.lock()
                if coalesce, queue.isEmpty, let l = latest { queue = [l] }
                cond.unlock()
                continue
            }

            cond.lock()
            let line = queue.isEmpty ? nil : queue.removeFirst()
            cond.unlock()
            guard let line else { continue }
            // If the game was lost, a stick or trigger's newest value is sent again on reconnect
            // (`latest`), and the reconnect's `pad release` drops any button the game still held.
            exchange(line)
        }
    }

    /// Sends one line and waits for the game's one-line answer. Nil when the connection failed.
    @discardableResult
    private func exchange(_ line: String) -> String? {
        guard fd >= 0 else { return nil }
        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress, buf.count)
            }
            if n <= 0 { lose("write failed"); return nil }
            sent += n
        }
        var reply = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { lose("the game closed the connection"); return nil }
            if byte == UInt8(ascii: "\n") { break }
            reply.append(byte)
            if reply.count > 1 << 20 { lose("answer too long"); return nil }
        }
        let text = String(decoding: reply, as: UTF8.self)
        if text.contains("\"error\"") {
            setError("Horizon said: \(text)")
        } else if lastError != nil {
            setError(nil)
        }
        return text
    }

    private func connect() -> Bool {
        let s = socket(AF_UNIX, Int32(SOCK_STREAM_VALUE), 0)
        if s < 0 { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(s)
            setError("socket path too long: \(path)")
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glue.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 {
            close(s)
            return false
        }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        fd = s
        connected = true
        lastError = nil
        onStatusChange?()
        return true
    }

    private func lose(_ why: String) {
        closeSocket()
        onStatusChange?()
    }

    private func closeSocket() {
        if fd >= 0 { close(fd) }
        fd = -1
        connected = false
    }

    private func setError(_ e: String?) {
        lastError = e
        onStatusChange?()
    }
}

/// `connect` is shadowed by `Channel.connect`; this reaches the C one.
enum Glue {
    static func connect(_ s: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(s, a, l)
        #else
        return Glibc.connect(s, a, l)
        #endif
    }
}

#if canImport(Darwin)
let SOCK_STREAM_VALUE = SOCK_STREAM
#else
let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
#endif

// MARK: - The bridge

/// Turns controller snapshots into commands on the channels.
final class Bridge {
    let buttons: Channel
    let left: Channel
    let right: Channel
    let lt: Channel
    let rt: Channel
    private var last = PadSnapshot.neutral
    private let lock = NSLock()
    /// When the controller was last away from rest.
    private var lastActive = Date()
    /// Whether the game has been told to let go of everything since the controller came to rest.
    private var releasedAtRest = false
    /// When the controller last reported anything.
    private var lastUpdate = Date()
    private var syncing = true

    init(path: String = horizonSocketPath()) {
        // A game that quits mid-write must not kill the app (SIGPIPE).
        signal(SIGPIPE, SIG_IGN)
        buttons = Channel(
            name: "buttons", path: path, coalesce: false, greeting: ["pad release", "pad family playstation"],
            keepalive: true)
        left = Channel(name: "left-stick", path: path, coalesce: true)
        right = Channel(name: "right-stick", path: path, coalesce: true)
        lt = Channel(name: "left-trigger", path: path, coalesce: true)
        rt = Channel(name: "right-trigger", path: path, coalesce: true)
        let t = Thread { [weak self] in
            while let self, self.syncing {
                self.resync()
                Thread.sleep(forTimeInterval: Bridge.resyncInterval)
            }
        }
        t.name = "bridge-resync"
        t.start()
    }

    static let resyncInterval = 0.5

    /// Keeps the game's idea of the controller equal to the controller, so nothing can stay stuck:
    /// - while the controller is in use, its sticks, triggers and held buttons are sent again
    ///   every half second (setting a value again is harmless);
    /// - once it has been at rest for half a second, the game is told to let go of everything
    ///   (`pad release`), once, which clears anything a lost message or the game left held.
    func resync(now: Date = Date()) {
        // The controller stopped reporting (switched off, out of range) with something held:
        // let go of it, or the game would keep walking.
        lock.lock()
        let stale = last != .neutral && now.timeIntervalSince(lastUpdate) > Bridge.resyncInterval
        lock.unlock()
        if stale {
            neutral()
            return
        }
        // Everything is queued under the lock, so a resync can never queue a value older than
        // one `update` queued just before it.
        lock.lock()
        defer { lock.unlock() }
        let s = last
        if s != .neutral {
            lastActive = now
            releasedAtRest = false
            left.send(Commands.stick("left", s.left))
            right.send(Commands.stick("right", s.right))
            lt.send(Commands.trigger("left", s.triggers[0]))
            rt.send(Commands.trigger("right", s.triggers[1]))
            for b in PadButton.allCases where s.buttons.contains(b) {
                buttons.send(Commands.button(b, true))
            }
        } else if !releasedAtRest && now.timeIntervalSince(lastActive) >= Bridge.resyncInterval {
            releasedAtRest = true
            buttons.send("pad release")
        }
    }

    var channels: [Channel] { [buttons, left, right, lt, rt] }
    var connected: Bool { channels.contains { $0.connected } }
    var lastError: String? { channels.compactMap { $0.lastError }.first }

    func update(_ s: PadSnapshot) {
        lock.lock()
        let d = Commands.diff(from: last, to: s)
        last = s
        lastUpdate = Date()
        if s != .neutral {
            lastActive = Date()
            releasedAtRest = false
        }
        for c in d.buttons { buttons.send(c) }
        if let c = d.left { left.send(c) }
        if let c = d.right { right.send(c) }
        if let c = d.lt { lt.send(c) }
        if let c = d.rt { rt.send(c) }
        lock.unlock()
    }

    /// Lets go of everything (the controller went away, Horizon isn't in front, the app quits),
    /// and tells the game to drop anything it still holds.
    func neutral() {
        update(.neutral)
        lock.lock()
        releasedAtRest = true
        buttons.send("pad release")
        lock.unlock()
    }

    /// Closes the connections to the game (the bridge was switched off).
    func stop() {
        syncing = false
        channels.forEach { $0.stop() }
    }

    var current: PadSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}


// MARK: - The link Trigger Lab's engine drives

#if canImport(AppKit)

/// Owns the bridge while "Play Horizon over Bluetooth" is on. Everything here runs on the main
/// thread (the HID callback and the engine's timer both do).
final class HorizonLink {
    private var bridge: Bridge?
    private var forwarding = false
    private var lastFullReport = Date.distantPast

    /// Only send the controller to Horizon while Horizon is the app in front.
    var frontOnly = true

    var isOn: Bool { bridge != nil }

    func setOn(_ on: Bool) {
        if on, bridge == nil {
            bridge = Bridge()
            forwarding = false
            refresh()
        } else if !on, let old = bridge {
            bridge = nil
            forwarding = false
            old.neutral()
            // Give the "let go of everything" a moment to reach the game before closing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { old.stop() }
        }
    }

    /// A full Bluetooth input report arrived.
    func handle(_ pad: PadSnapshot) {
        lastFullReport = Date()
        if forwarding { bridge?.update(pad) }
    }

    /// The controller went away.
    func controllerRemoved() {
        bridge?.neutral()
    }

    /// Call a few times a second: follows which app is in front.
    func refresh() {
        guard let bridge else { return }
        let now = !frontOnly || HorizonLink.horizonInFront()
        if forwarding && !now { bridge.neutral() }
        forwarding = now
    }

    /// The app is quitting: don't leave anything held in the game.
    func shutdown() {
        guard let bridge else { return }
        bridge.neutral()
        Thread.sleep(forTimeInterval: 0.15)
    }

    static func horizonInFront() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let exe = app.executableURL?.lastPathComponent.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        return exe.hasPrefix("horizon") || name.contains("horizon")
    }

    /// One line for the panel. `connection` is "USB", "Bluetooth" or nil (no controller).
    func status(connection: String?) -> String {
        guard let bridge else { return "" }
        if let error = bridge.lastError { return String(error.prefix(140)) }
        guard bridge.connected else {
            return "Horizon not found. Start Horizon; if this stays, turn on Agent Control in Horizon Settings > Extras."
        }
        guard let connection else { return "Horizon found. No DualSense connected." }
        if connection == "USB" { return "Horizon found. Over USB Horizon reads the controller by itself." }
        if Date().timeIntervalSince(lastFullReport) > 1.5 {
            return "Horizon found. Waiting for the controller: press a button."
        }
        return forwarding ? "Sending your controller to Horizon."
                          : "Horizon found. Paused until Horizon is the app in front."
    }
}
#endif
