import Foundation
import IOKit
import IOKit.hid

/// Talks to the DualSense directly over HID, the same way Steam and most PC tools do.
/// Apple's GameController trigger API doesn't reliably reach the controller on macOS,
/// so this sends the raw output reports instead.
final class DualSenseHID {
    enum Status: Equatable {
        case ready
        case noAccess
        case failed(Int32)
    }

    private static let notPermitted = IOReturn(bitPattern: 0xE00002E2)
    private static let sonyVendor = 0x054C
    private static let productIDs = [0x0CE6, 0x0DF2] // DualSense, DualSense Edge

    private let manager: IOHIDManager
    private(set) var status: Status
    private var bluetoothSequence: UInt8 = 0

    /// Raw trigger positions straight from the controller (0...1), with no dead zone.
    /// Called on the main thread whenever L2 or R2 moves.
    var onTriggers: ((Float, Float) -> Void)?
    private var lastL2: UInt8 = 0
    private var lastR2: UInt8 = 0

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = DualSenseHID.productIDs.map {
            ["VendorID": DualSenseHID.sonyVendor, "ProductID": $0] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            status = .ready
        } else if result == DualSenseHID.notPermitted {
            status = .noAccess
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            status = .failed(result)
        }

        // Read input reports so the app sees the true trigger position.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let hid = Unmanaged<DualSenseHID>.fromOpaque(context).takeUnretainedValue()
            hid.handleInput(reportID: reportID, report: report, length: length)
        }, context)
    }

    /// Called on the main thread when ✕ goes down (used to record calibration points).
    var onCross: (() -> Void)?
    private var lastCross = false

    /// The most recent input report, for the diagnostics readout and calibration.
    private(set) var latest: HIDInputSnapshot?
    private(set) var reportCount = 0
    private var lastInputTime: TimeInterval = -.infinity

    /// True while input reports are arriving. If not, live values come from GameController.
    var inputIsLive: Bool { ProcessInfo.processInfo.systemUptime - lastInputTime < 1 }

    /// Input Monitoring permission, which macOS can require before it delivers input reports.
    var accessDescription: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "not decided"
        }
    }

    private func handleInput(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 0 else { return }
        let raw = UnsafeBufferPointer(start: report, count: length)

        let kind: HIDInputSnapshot.Kind
        let sizeWithID: Int
        switch reportID {
        case 0x31: kind = .bluetoothFull; sizeWithID = 78
        case 0x01 where length >= 60: kind = .usb; sizeWithID = 64
        case 0x01: kind = .bluetoothBasic; sizeWithID = 10
        default: return
        }
        // Some macOS versions include the report ID as the first byte, some don't. The sizes are
        // fixed, so tell by length; only fall back to looking at the first byte for odd sizes
        // (a stick value can equal the report ID, so the byte alone isn't reliable).
        let idIncluded: Bool
        if length == sizeWithID { idIncluded = true }
        else if length == sizeWithID - 1 { idIncluded = false }
        else { idIncluded = UInt32(raw[0]) == reportID }

        let snapshot = HIDInputSnapshot(kind: kind, reportID: UInt8(truncatingIfNeeded: reportID),
                                        length: length, idIncluded: idIncluded,
                                        payload: Array(raw[(idIncluded ? 1 : 0)...]))
        guard let l2 = snapshot.l2, let r2 = snapshot.r2 else { return }
        reportCount += 1
        lastInputTime = ProcessInfo.processInfo.systemUptime
        latest = snapshot

        let cross = snapshot.crossPressed
        if cross && !lastCross { onCross?() }
        lastCross = cross

        guard l2 != lastL2 || r2 != lastR2 else { return }
        lastL2 = l2
        lastR2 = r2
        onTriggers?(Float(l2) / 255, Float(r2) / 255)
    }

    /// "USB" or "Bluetooth" for the first connected DualSense, nil if none.
    var connection: String? {
        guard let device = devices.first else { return nil }
        return isBluetooth(device) ? "Bluetooth" : "USB"
    }

    var hasDevice: Bool { !devices.isEmpty }

    private var devices: [IOHIDDevice] {
        guard status == .ready, let set = IOHIDManagerCopyDevices(manager) else { return [] }
        let count = CFSetGetCount(set)
        guard count > 0 else { return [] }
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(set, &values)
        return values.compactMap { pointer in
            pointer.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }
        }
    }

    private func isBluetooth(_ device: IOHIDDevice) -> Bool {
        let transport = IOHIDDeviceGetProperty(device, "Transport" as CFString) as? String ?? ""
        return transport.lowercased().contains("bluetooth")
    }

    /// Sends new effects. Pass nil for anything you want to leave untouched.
    /// `light` is red, green, blue (0...255).
    @discardableResult
    func send(left: [UInt8]?, right: [UInt8]?, light: [UInt8]? = nil) -> Bool {
        guard left != nil || right != nil || light != nil else { return true }
        var sentAny = false

        for device in devices {
            // The firmware can keep the light bar in its own startup state and ignore colors until
            // it's released (the Linux driver does this once per controller). Do the same the first
            // time we set a color on each controller.
            if light != nil, !lightReleased.contains(deviceID(device)) {
                var setup = [UInt8](repeating: 0, count: 47)
                setup[38] = 0x02 // allow light bar setup
                setup[41] = 0x02 // light bar setup: release (fade out the default light)
                if write(setup, to: device) == kIOReturnSuccess { lightReleased.insert(deviceID(device)) }
            }

            // Shared part of the report (47 bytes), same for USB and Bluetooth.
            var common = [UInt8](repeating: 0, count: 47)
            if let right {
                common[0] |= 0x04 // allow right trigger effect
                for i in 0..<11 { common[10 + i] = right[i] }
            }
            if let left {
                common[0] |= 0x08 // allow left trigger effect
                for i in 0..<11 { common[21 + i] = left[i] }
            }
            if let light, light.count == 3 {
                common[1] |= 0x04 // allow light bar color
                common[44] = light[0]
                common[45] = light[1]
                common[46] = light[2]
            }
            if write(common, to: device) == kIOReturnSuccess { sentAny = true }
        }
        return sentAny
    }

    /// Result of the last output report, for the diagnostics readout.
    private(set) var lastSendResult: IOReturn?
    private var lightReleased: Set<UInt64> = []

    private func deviceID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    /// Wraps the shared 47 bytes in a USB or Bluetooth output report and sends it.
    private func write(_ common: [UInt8], to device: IOHIDDevice) -> IOReturn {
        var report: [UInt8]
        if isBluetooth(device) {
            report = [UInt8](repeating: 0, count: 78)
            report[0] = 0x31
            report[1] = bluetoothSequence << 4
            report[2] = 0x10
            bluetoothSequence = (bluetoothSequence + 1) & 0x0F
            for i in 0..<common.count { report[3 + i] = common[i] }
            let crc = CRC32.checksum([0xA2] + report[0..<74])
            report[74] = UInt8(crc & 0xFF)
            report[75] = UInt8((crc >> 8) & 0xFF)
            report[76] = UInt8((crc >> 16) & 0xFF)
            report[77] = UInt8((crc >> 24) & 0xFF)
        } else {
            report = [UInt8](repeating: 0, count: 48)
            report[0] = 0x02
            for i in 0..<common.count { report[1 + i] = common[i] }
        }

        let reportID = CFIndex(report[0])
        let result = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID,
                                 buffer.baseAddress!, buffer.count)
        }
        lastSendResult = result
        return result
    }
}

// MARK: - Input reports

/// One DualSense input report. `payload` is the report without its ID byte.
struct HIDInputSnapshot {
    enum Kind: String {
        case usb = "USB"
        case bluetoothFull = "Bluetooth (full)"
        case bluetoothBasic = "Bluetooth (basic)"
    }

    let kind: Kind
    let reportID: UInt8
    let length: Int
    let idIncluded: Bool
    let payload: [UInt8]

    /// Where the full input layout starts in the payload. Bluetooth adds one byte in front;
    /// the basic Bluetooth report has a different, shorter layout.
    var layoutStart: Int? {
        switch kind {
        case .usb: return 0
        case .bluetoothFull: return 1
        case .bluetoothBasic: return nil
        }
    }

    /// A byte at an offset in the full input layout (nil for the basic Bluetooth report).
    func layoutByte(_ offset: Int) -> UInt8? {
        guard let start = layoutStart, start + offset < payload.count else { return nil }
        return payload[start + offset]
    }

    private func byte(_ i: Int) -> UInt8? { i < payload.count ? payload[i] : nil }

    var l2: UInt8? { layoutStart != nil ? layoutByte(4) : byte(7) }
    var r2: UInt8? { layoutStart != nil ? layoutByte(5) : byte(8) }

    /// ✕ is bit 5 of the first button byte (D-pad in the low 4 bits, then □ ✕ ○ △).
    var crossPressed: Bool {
        let buttons = layoutStart != nil ? layoutByte(7) : byte(4)
        return (buttons ?? 0) & 0x20 != 0
    }

    /// Trigger motor state, per community reverse-engineering of the full input report
    /// (not documented by Sony): 0x29 = R2, 0x2A = L2, each "stop location" (low 4 bits,
    /// 0...9) and "status" (high 4 bits); 0x2F = active effect (R2 low bits, L2 high bits).
    func motorByte(_ side: TriggerSide) -> UInt8? { layoutByte(side == .left ? 0x2A : 0x29) }
    var effectByte: UInt8? { layoutByte(0x2F) }
}

// MARK: - Effect encoding

/// Builds the 11-byte effect blocks the DualSense firmware understands.
/// Positions are zones 0...9 along the trigger's travel; strengths are 1...8.
enum TriggerEffect {
    static func off() -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 11)
        e[0] = 0x05
        return e
    }

    /// One strength per zone (0 = no resistance in that zone, 1...8 = stiffness).
    static func feedback(zones: [Int]) -> [UInt8] {
        var active: UInt16 = 0
        var forces: UInt32 = 0
        for (i, strength) in zones.prefix(10).enumerated() where strength > 0 {
            let value = UInt32((min(strength, 8) - 1) & 0x07)
            forces |= value << (3 * UInt32(i))
            active |= 1 << UInt16(i)
        }
        guard active != 0 else { return off() }
        var e = [UInt8](repeating: 0, count: 11)
        e[0] = 0x21
        e[1] = UInt8(active & 0xFF)
        e[2] = UInt8(active >> 8)
        e[3] = UInt8(forces & 0xFF)
        e[4] = UInt8((forces >> 8) & 0xFF)
        e[5] = UInt8((forces >> 16) & 0xFF)
        e[6] = UInt8((forces >> 24) & 0xFF)
        return e
    }

    /// Resistance between start and end that suddenly lets go. Start 2...7, end start+1...8.
    static func weapon(start: Int, end: Int, strength: Int) -> [UInt8] {
        guard strength > 0 else { return off() }
        let s = min(max(start, 2), 7)
        let en = min(max(end, s + 1), 8)
        let zones: UInt16 = (1 << UInt16(s)) | (1 << UInt16(en))
        var e = [UInt8](repeating: 0, count: 11)
        e[0] = 0x25
        e[1] = UInt8(zones & 0xFF)
        e[2] = UInt8(zones >> 8)
        e[3] = UInt8(min(strength, 8) - 1)
        return e
    }

    /// Buzzing from the start zone down. Amplitude 1...8, frequency in Hz (1...255).
    static func vibration(start: Int, amplitude: Int, frequency: Int) -> [UInt8] {
        let s = min(max(start, 0), 9)
        return vibration(zones: (0..<10).map { $0 >= s ? amplitude : 0 }, frequency: frequency)
    }

    /// One amplitude per zone (0 = still, 1...8 = buzz strength), frequency in Hz (1...255).
    static func vibration(zones: [Int], frequency: Int) -> [UInt8] {
        var active: UInt16 = 0
        var amps: UInt32 = 0
        for (i, amplitude) in zones.prefix(10).enumerated() where amplitude > 0 {
            amps |= UInt32((min(amplitude, 8) - 1) & 0x07) << (3 * UInt32(i))
            active |= 1 << UInt16(i)
        }
        guard active != 0, frequency > 0 else { return off() }
        var e = [UInt8](repeating: 0, count: 11)
        e[0] = 0x26
        e[1] = UInt8(active & 0xFF)
        e[2] = UInt8(active >> 8)
        e[3] = UInt8(amps & 0xFF)
        e[4] = UInt8((amps >> 8) & 0xFF)
        e[5] = UInt8((amps >> 16) & 0xFF)
        e[6] = UInt8((amps >> 24) & 0xFF)
        e[9] = UInt8(min(frequency, 255))
        return e
    }

    // MARK: From the app's settings

    private static func level(_ strength: Double) -> Int {
        strength <= 0.01 ? 0 : Int((min(strength, 1) * 7).rounded()) + 1
    }

    static func from(_ s: TriggerSettings) -> [UInt8] {
        switch s.mode {
        case .off:
            return off()
        case .resistance, .twoStage, .progressive:
            return feedback(zones: s.zoneLevels.map(level))
        case .click:
            return weapon(start: s.startZone, end: s.endZone, strength: level(s.strength))
        case .rumble, .burst:
            return rumbleOn(s)
        case .custom:
            // Drawn in eighths, so each step maps straight onto the controller's 8 levels.
            let zones = s.customLevels.map { Int(($0 * 8).rounded()) }
            return s.vibratesInCustom ? vibration(zones: zones, frequency: frequencyHz(s)) : feedback(zones: zones)
        }
    }

    private static func frequencyHz(_ s: TriggerSettings) -> Int {
        5 + Int((min(max(s.frequency, 0), 1) * 75).rounded()) // 5...80 Hz
    }

    static func rumbleOn(_ s: TriggerSettings) -> [UInt8] {
        vibration(start: s.startZone, amplitude: level(s.amplitude), frequency: frequencyHz(s))
    }
}

// MARK: - CRC32 (needed for Bluetooth reports)

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
