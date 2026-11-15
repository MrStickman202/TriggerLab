// Tests for Sources/HorizonBridge.swift (not part of the app; build.sh only compiles Sources/).
// Run: swiftc -swift-version 5 Sources/HorizonBridge.swift Tests/main.swift -o /tmp/t && /tmp/t
// Set HORIZON_TEST_SOCKET to a fake game's socket to also run the socket test.
import Foundation

var failures = 0
func check(_ cond: Bool, _ what: String, line: Int = #line) {
    if !cond {
        failures += 1
        print("FAIL (line \(line)): \(what)")
    }
}

/// A Bluetooth 0x31 report at rest: sticks centred, hat released, nothing pressed.
func restReport() -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 78)
    r[0] = 0x31
    r[1] = 0x10
    r[2] = 128; r[3] = 128; r[4] = 128; r[5] = 128  // sticks
    r[6] = 0; r[7] = 0  // triggers
    r[9] = 0x08  // hat released
    return r
}

// Rest is neutral.
check(DualSense.parse(restReport()) == .neutral, "a resting pad is neutral")

// Other reports are ignored: the simple report and a USB report.
var simple = restReport(); simple[0] = 0x01
check(DualSense.parse(simple) == nil, "report 0x01 is Horizon's own")
check(DualSense.parse([0x31, 0, 1]) == nil, "a short report is ignored")

// Face buttons.
var r = restReport()
r[9] = 0x08 | 0x20  // cross
check(DualSense.parse(r)?.buttons == [.south], "cross is south")
r[9] = 0x08 | 0x10 | 0x40 | 0x80
check(DualSense.parse(r)?.buttons == [.west, .east, .north], "square, circle, triangle")

// D-pad hat.
let hats: [(UInt8, Set<PadButton>)] = [
    (0, [.up]), (1, [.up, .right]), (2, [.right]), (3, [.down, .right]),
    (4, [.down]), (5, [.down, .left]), (6, [.left]), (7, [.up, .left]), (8, []),
]
for (h, want) in hats {
    r = restReport(); r[9] = h
    check(DualSense.parse(r)?.buttons == want, "hat \(h)")
}

// Shoulders, Create, Options, stick clicks; L2/R2 digital bits are ignored (analog instead).
r = restReport(); r[10] = 0xFF
check(DualSense.parse(r)?.buttons == [.lb, .rb, .select, .start, .ls, .rs], "second byte")

// Sticks: up is positive, full tilt reaches ±1, the centre snaps to 0.
r = restReport(); r[2] = 255; r[3] = 0
let s = DualSense.parse(r)!
check(s.left == [1, 1], "left stick right and up: \(s.left)")
r = restReport(); r[4] = 0; r[5] = 255
check(DualSense.parse(r)!.right == [-1, -1], "right stick left and down")
r = restReport(); r[2] = 131; r[3] = 125
check(DualSense.parse(r)!.left == [0, 0], "drift near the centre is 0")
r = restReport(); r[3] = 64
let half = DualSense.parse(r)!.left
check(half[0] == 0 && abs(half[1] - 0.498) < 0.01, "half tilt up: \(half)")

// Triggers.
r = restReport(); r[6] = 255; r[7] = 128
let t = DualSense.parse(r)!.triggers
check(t[0] == 1 && abs(t[1] - 0.502) < 0.01, "triggers \(t)")
r = restReport(); r[6] = 3
check(DualSense.parse(r)!.triggers[0] == 0, "a resting trigger is 0")

// Commands.
check(Commands.button(.south, true) == "pad south down", "button down")
check(Commands.button(.up, false) == "pad up up", "d-pad up released")
check(Commands.stick("left", [0.5, -1]) == "pad stick left 0.500 -1.000", "stick command")
check(Commands.trigger("right", 0.25) == "pad trigger right 0.250", "trigger command")

// Diffs: only what changed.
var a = PadSnapshot.neutral
var b = a; b.buttons = [.south, .lb]; b.left = [0.3, 0.3]
var d = Commands.diff(from: a, to: b)
check(d.buttons == ["pad south down", "pad lb down"], "presses in order: \(d.buttons)")
check(d.left == "pad stick left 0.300 0.300", "left moved")
check(d.right == nil && d.lt == nil && d.rt == nil, "nothing else")
a = b; b.left = [0.305, 0.3]
d = Commands.diff(from: a, to: b)
check(d.left == nil && d.buttons.isEmpty, "a tiny move is not sent")
a = b; b.left = [0, 0]; b.buttons = []
d = Commands.diff(from: a, to: b)
check(d.left == "pad stick left 0.000 0.000", "back to centre is always sent")
check(d.buttons == ["pad south up", "pad lb up"], "releases")
var tiny = PadSnapshot.neutral; tiny.triggers = [0.005, 0]
check(Commands.diff(from: tiny, to: .neutral).lt == "pad trigger left 0.000", "trigger back to 0")

// Socket path.
check(horizonSocketPath(environment: ["HORIZON_CONTROL": "/x/y.sock"]) == "/x/y.sock", "env wins")
check(
    horizonSocketPath(environment: ["XDG_RUNTIME_DIR": "/run/u"]) == "/run/u/horizon-control.sock",
    "runtime dir")
check(horizonSocketPath(environment: [:]).hasSuffix("horizon-control.sock"), "temp dir")

// The socket, against a fake game that logs every line it gets.
if let path = ProcessInfo.processInfo.environment["HORIZON_TEST_SOCKET"] {
    let bridge = Bridge(path: path)
    Thread.sleep(forTimeInterval: 1.5)
    check(bridge.connected, "the bridge connects")
    var p = PadSnapshot.neutral
    p.buttons = [.south]
    p.left = [1, 0]
    p.triggers = [0.8, 0]
    bridge.update(p)
    for x in stride(from: 0.0, through: 1.0, by: 0.05) {  // a burst of stick moves
        var q = p; q.right = [x, 0]; bridge.update(q)
    }
    var q = p; q.right = [1, 0]; q.buttons = []
    bridge.update(q)
    Thread.sleep(forTimeInterval: 0.5)
    bridge.neutral()
    Thread.sleep(forTimeInterval: 3)  // long enough for a keepalive
    print("socket test sent; the fake game checks the log")
}

// A controller that stops reporting with a stick held is let go.
do {
    let bridge = Bridge(path: "/nonexistent/horizon.sock")
    var held = PadSnapshot.neutral
    held.left = [1, 0]
    bridge.update(held)
    bridge.resync(now: Date().addingTimeInterval(0.2))
    check(bridge.current == held, "still held while reports are recent")
    bridge.resync(now: Date().addingTimeInterval(2))
    check(bridge.current == .neutral, "let go once the controller went quiet")
    bridge.stop()
}

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
