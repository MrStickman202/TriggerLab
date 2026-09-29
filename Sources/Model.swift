import Foundation
import GameController

// MARK: - Trigger modes

enum TriggerSide: String, CaseIterable, Codable, Hashable {
    case left, right
    var label: String { self == .left ? "L2" : "R2" }
}

enum TriggerMode: String, CaseIterable, Codable, Identifiable {
    case off, resistance, twoStage, progressive, click, rumble, burst, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .resistance: return "Resistance"
        case .twoStage: return "Two-stage"
        case .progressive: return "Progressive"
        case .click: return "Click"
        case .rumble: return "Rumble"
        case .burst: return "Burst"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .off:
            return "Leaves this trigger alone, so games and mods can use their own effects."
        case .resistance:
            return "Same stiffness from the start point to the end point (100% = all the way down). Good for aiming, steering and heavy objects."
        case .twoStage:
            return "Light first stage, then a harder wall. Half-press to aim, push through to act."
        case .progressive:
            return "Gets stiffer the further you press, like a bowstring or a car brake."
        case .click:
            return "Resistance that suddenly breaks at the end point, like a real gun trigger. The controller only allows the click between about 20% and 90% of the pull."
        case .rumble:
            return "The trigger buzzes once you press past the start point. Feels like automatic fire or an engine."
        case .burst:
            return "Buzzes in short on/off pulses, like burst fire. Set the rhythm below."
        case .custom:
            return "Draw your own: drag on the graph to set each of the 10 zones. Pick resistance or vibration below."
        }
    }

    /// Which controller effect this mode is sent as. Each one is calibrated separately,
    /// since the firmware may place its zones differently per effect.
    var family: EffectFamily? {
        switch self {
        case .off: return nil
        case .resistance, .twoStage, .progressive: return .feedback
        case .click: return .weapon
        case .rumble, .burst: return .vibration
        case .custom: return nil // depends on the custom effect type, see TriggerSettings.family
        }
    }

    var usesEnd: Bool { self == .resistance || self == .twoStage || self == .progressive || self == .click }
    var usesFirstStrength: Bool { self == .twoStage || self == .progressive }
    var usesStrength: Bool { self == .resistance || self == .twoStage || self == .progressive || self == .click }
    var usesRumble: Bool { self == .rumble || self == .burst }
    var usesBurst: Bool { self == .burst }

    var endTitle: String {
        switch self {
        case .click: return "Breaks at"
        case .twoStage: return "Second stage at"
        case .resistance: return "Ends at"
        default: return "Full stiffness at"
        }
    }

    var firstStrengthTitle: String {
        self == .twoStage ? "First stage stiffness" : "Starting stiffness"
    }

    var strengthTitle: String {
        switch self {
        case .twoStage: return "Second stage stiffness"
        case .progressive: return "Final stiffness"
        case .click: return "Click stiffness"
        default: return "Stiffness"
        }
    }
}

struct TriggerSettings: Codable, Equatable {
    var mode: TriggerMode = .off
    var start: Double = 0.2
    var end: Double = 0.6
    var firstStrength: Double = 0.2
    var strength: Double = 0.7
    var amplitude: Double = 0.6
    var frequency: Double = 0.6
    var burstOnMs: Double = 90
    var burstOffMs: Double = 90
    /// Where Resistance stops. nil means all the way down, which is how settings and
    /// profiles from before this option load (optional so older saved settings still decode).
    var resistanceEnd: Double? = nil
    /// Custom mode: strength (0...1) of each of the 10 zones, drawn on the graph.
    /// Optional so settings saved before Custom existed still decode.
    var customZones: [Double]? = nil
    /// Custom mode: vibrate in the drawn zones instead of resisting.
    var customVibrates: Bool? = nil

    var customLevels: [Double] {
        get {
            let z = customZones ?? []
            return (0..<10).map { $0 < z.count ? min(max(z[$0], 0), 1) : 0 }
        }
        set { customZones = newValue }
    }

    var vibratesInCustom: Bool {
        get { customVibrates ?? false }
        set { customVibrates = newValue }
    }

    /// Which controller effect these settings are sent as (nil for Off).
    var family: EffectFamily? {
        mode == .custom ? (vibratesInCustom ? .vibration : .feedback) : mode.family
    }

    /// Whether the trigger buzzes rather than resists.
    var isRumble: Bool { family == .vibration }

    /// Resistance's end point for the slider (1 = all the way down).
    var resistanceStop: Double {
        get { resistanceEnd ?? 1 }
        set { resistanceEnd = newValue >= 0.999 ? nil : newValue }
    }

    /// End point, always a little past the start point (the controller requires end > start).
    var safeEnd: Double { min(1, max(mode == .resistance ? resistanceStop : end, start + 0.05)) }

    /// The controller splits the trigger's travel into 10 zones (0 = released, 9 = fully pressed).
    static func zone(_ position: Double) -> Int {
        min(9, max(0, Int((position * 10).rounded())))
    }

    /// First zone where the effect kicks in (the click effect only works in zones 2...7).
    var startZone: Int {
        let z = TriggerSettings.zone(start)
        return mode == .click ? min(max(z, 2), 7) : z
    }

    /// Zone where the second stage / full stiffness / click break happens.
    var endZone: Int {
        let z = Int((min(max(safeEnd, 0), 1) * 10).rounded())
        if mode == .click { return min(max(z, startZone + 1), 8) }
        return min(max(z, startZone + 1), 10)
    }

    /// Effect strength (0...1) in each of the 10 zones. This is exactly what gets sent
    /// to the controller, and the preview graph draws the same numbers.
    var zoneLevels: [Double] {
        let sz = startZone, ez = endZone
        return (0..<10).map { i in
            switch mode {
            case .off:
                return 0
            case .resistance:
                return (i >= sz && i < ez) ? strength : 0
            case .twoStage:
                if i < sz { return 0 }
                return i < ez ? firstStrength : strength
            case .progressive:
                if i < sz { return 0 }
                if i >= ez { return strength }
                let t = Double(i - sz) / Double(max(1, ez - sz))
                return firstStrength + (strength - firstStrength) * t
            case .click:
                return (i >= sz && i < ez) ? strength : 0
            case .rumble, .burst:
                return i >= sz ? amplitude : 0
            case .custom:
                return customLevels[i]
            }
        }
    }
}

// MARK: - Calibration

/// The three effect types the controller has. Every mode is sent as one of them.
enum EffectFamily: String, CaseIterable, Codable, Identifiable {
    case feedback, weapon, vibration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feedback: return "Resistance, Two-stage, Progressive"
        case .weapon: return "Click"
        case .vibration: return "Rumble, Burst"
        }
    }

    /// Zones to test. Click only works with a start between zones 2 and 7.
    var testZones: [Int] {
        switch self {
        case .feedback: return [1, 2, 4, 6, 8]
        case .weapon: return [2, 3, 5, 7]
        case .vibration: return [1, 3, 5, 7]
        }
    }

    var instruction: String {
        switch self {
        case .feedback, .weapon:
            return "Press slowly until you hit the wall. Hold it there, touching the wall without pushing through, then press ✕."
        case .vibration:
            return "Press slowly until it starts buzzing. Hold it right there, then press ✕."
        }
    }

    /// The test effect: a full-strength wall (or buzz) starting at `zone`.
    func testEffect(zone: Int) -> [UInt8] {
        switch self {
        case .feedback:
            return TriggerEffect.feedback(zones: (0..<10).map { $0 >= zone ? 8 : 0 })
        case .weapon:
            return TriggerEffect.weapon(start: zone, end: zone + 1, strength: 8)
        case .vibration:
            return TriggerEffect.vibration(start: zone, amplitude: 8, frequency: 40)
        }
    }
}

struct CalibrationPoint: Codable, Equatable {
    var zone: Int
    /// Analog trigger value (0...1) when the effect was felt.
    var analog: Double
    /// Raw motor byte from the input report at that moment, kept for diagnosis.
    var motor: UInt8?
}

/// Where each zone's effect is actually felt, in analog trigger values, for one trigger.
struct TriggerCalibration: Codable, Equatable {
    var points: [String: [CalibrationPoint]] = [:]

    func points(for family: EffectFamily) -> [CalibrationPoint] {
        points[family.rawValue] ?? []
    }

    mutating func setPoints(_ p: [CalibrationPoint], for family: EffectFamily) {
        points[family.rawValue] = p.isEmpty ? nil : p
    }

    /// Converts an analog trigger value into the graph's position (zone / 10), so the live marker
    /// reaches a zone's bars exactly when you feel that zone's effect. Uncalibrated: unchanged.
    func position(analog: Double, family: EffectFamily?) -> Double {
        guard let family else { return analog }
        var knots: [(analog: Double, position: Double)] = [(0, 0)]
        for p in points(for: family).sorted(by: { $0.zone < $1.zone }) {
            let position = Double(p.zone) / 10
            // Skip points that would make the curve go backwards (e.g. a zone felt while the
            // analog value still reads 0: nothing can be told apart inside that stretch).
            guard p.analog > knots[knots.count - 1].analog + 0.005,
                  position > knots[knots.count - 1].position else { continue }
            knots.append((p.analog, position))
        }
        guard knots.count > 1 else { return analog }
        if knots[knots.count - 1].analog < 1 { knots.append((1, 1)) }

        let a = min(max(analog, 0), 1)
        for i in 1..<knots.count where a <= knots[i].analog {
            let lo = knots[i - 1], hi = knots[i]
            let t = (a - lo.analog) / (hi.analog - lo.analog)
            return lo.position + (hi.position - lo.position) * t
        }
        return 1
    }
}

// MARK: - Profiles

struct Profile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var note: String
    var left: TriggerSettings
    var right: TriggerSettings

    var isBuiltIn: Bool { id.hasPrefix("builtin.") }
}

extension Profile {
    static let builtIns: [Profile] = [
        Profile(id: "builtin.off", name: "Off", note: "Both triggers are left alone.",
                left: .init(), right: .init()),

        Profile(id: "builtin.pistol", name: "Pistol",
                note: "Light aim on L2, crisp trigger break on R2.",
                left: .init(mode: .resistance, start: 0.1, strength: 0.25),
                right: .init(mode: .click, start: 0.3, end: 0.5, strength: 0.8)),

        Profile(id: "builtin.rifle", name: "Heavy rifle / shotgun",
                note: "Long, heavy pull that snaps near the bottom.",
                left: .init(mode: .resistance, start: 0.1, strength: 0.35),
                right: .init(mode: .click, start: 0.4, end: 0.8, strength: 1.0)),

        Profile(id: "builtin.smg", name: "Machine gun",
                note: "R2 rattles like automatic fire while held.",
                left: .init(mode: .resistance, start: 0.1, strength: 0.3),
                right: .init(mode: .rumble, start: 0.1, amplitude: 0.8, frequency: 0.85)),

        Profile(id: "builtin.burst", name: "Burst rifle",
                note: "R2 fires in short rhythmic pulses while held.",
                left: .init(mode: .resistance, start: 0.1, strength: 0.3),
                right: .init(mode: .burst, start: 0.1, amplitude: 1.0, frequency: 0.9, burstOnMs: 70, burstOffMs: 120)),

        Profile(id: "builtin.tactical", name: "Aim then fire",
                note: "L2 half-press to aim with a wall before full zoom; R2 short click.",
                left: .init(mode: .twoStage, start: 0.0, end: 0.5, firstStrength: 0.15, strength: 0.9),
                right: .init(mode: .click, start: 0.2, end: 0.4, strength: 0.7)),

        Profile(id: "builtin.bow", name: "Bow",
                note: "R2 gets harder the further you draw.",
                left: .init(mode: .resistance, start: 0.1, strength: 0.2),
                right: .init(mode: .progressive, start: 0.0, end: 0.9, firstStrength: 0.05, strength: 1.0)),

        Profile(id: "builtin.racing", name: "Racing",
                note: "Firm brake on L2, light spring on the throttle.",
                left: .init(mode: .progressive, start: 0.0, end: 0.8, firstStrength: 0.15, strength: 1.0),
                right: .init(mode: .resistance, start: 0.0, strength: 0.2)),

        Profile(id: "builtin.abs", name: "Racing with ABS",
                note: "L2 shudders when you brake hard; R2 throttle stiffens as you floor it.",
                left: .init(mode: .rumble, start: 0.5, amplitude: 0.6, frequency: 0.35),
                right: .init(mode: .progressive, start: 0.0, end: 1.0, firstStrength: 0.05, strength: 0.45)),

        Profile(id: "builtin.melee", name: "Melee / action",
                note: "Short, snappy clicks on both triggers. Nice for fast games like Hades.",
                left: .init(mode: .click, start: 0.2, end: 0.3, strength: 0.5),
                right: .init(mode: .click, start: 0.2, end: 0.3, strength: 0.5)),

        Profile(id: "builtin.minecraft", name: "Minecraft (Controlify)",
                note: "Made for Controlify's layout: L2 place/use gets a light click, R2 attack/mine gets a slow rumble.",
                left: .init(mode: .click, start: 0.2, end: 0.4, strength: 0.4),
                right: .init(mode: .rumble, start: 0.3, amplitude: 0.35, frequency: 0.3)),

        Profile(id: "builtin.stops", name: "Trigger stops",
                note: "A hard wall at 30% so short presses register faster.",
                left: .init(mode: .resistance, start: 0.3, strength: 1.0),
                right: .init(mode: .resistance, start: 0.3, strength: 1.0)),

        Profile(id: "builtin.max", name: "Maximum resistance",
                note: "Both triggers as stiff as they go. Mostly for fun.",
                left: .init(mode: .resistance, start: 0.0, strength: 1.0),
                right: .init(mode: .resistance, start: 0.0, strength: 1.0)),
    ]
}

// MARK: - Light bar

struct LightColor: Codable, Equatable {
    var red: Double = 0.2
    var green: Double = 0.4
    var blue: Double = 1.0
    var brightness: Double = 1.0

    /// Bytes for the controller, with brightness applied.
    var bytes: [UInt8] {
        [red, green, blue].map { UInt8((min(max($0 * brightness, 0), 1) * 255).rounded()) }
    }

    /// Hue and saturation (0...1) of the color, for the color wheel.
    var hueSaturation: (hue: Double, saturation: Double) {
        let mx = max(red, green, blue), mn = min(red, green, blue)
        guard mx > 0 else { return (0, 0) }
        let d = mx - mn
        guard d > 0 else { return (0, 0) }
        var h: Double
        if mx == red { h = (green - blue) / d }
        else if mx == green { h = 2 + (blue - red) / d }
        else { h = 4 + (red - green) / d }
        h /= 6
        if h < 0 { h += 1 }
        return (h, d / mx)
    }

    func sameHue(as other: LightColor) -> Bool {
        abs(red - other.red) < 0.01 && abs(green - other.green) < 0.01 && abs(blue - other.blue) < 0.01
    }
}

extension LightColor {
    /// A fully bright color with the given hue and saturation (0...1).
    init(hue: Double, saturation: Double, brightness: Double = 1) {
        let h = (hue - floor(hue)) * 6
        let s = min(max(saturation, 0), 1)
        let f = h - floor(h)
        let p = 1 - s, q = 1 - s * f, t = 1 - s * (1 - f)
        let rgb: (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: rgb = (1, t, p)
        case 1: rgb = (q, 1, p)
        case 2: rgb = (p, 1, t)
        case 3: rgb = (p, q, 1)
        case 4: rgb = (t, p, 1)
        default: rgb = (1, p, q)
        }
        self.init(red: rgb.0, green: rgb.1, blue: rgb.2, brightness: brightness)
    }
}

/// What the light bar does: hold one color, or cycle smoothly through all of them.
enum LightEffect: String, CaseIterable, Codable, Identifiable {
    case solid, rainbow
    var id: String { rawValue }
    var title: String { self == .solid ? "Color" : "Rainbow" }
}

struct LightSwatch: Identifiable {
    let name: String
    let color: LightColor
    var id: String { name }

    static let all: [LightSwatch] = [
        LightSwatch(name: "Red", color: .init(red: 1, green: 0, blue: 0)),
        LightSwatch(name: "Orange", color: .init(red: 1, green: 0.4, blue: 0)),
        LightSwatch(name: "Yellow", color: .init(red: 1, green: 0.85, blue: 0)),
        LightSwatch(name: "Green", color: .init(red: 0, green: 1, blue: 0.1)),
        LightSwatch(name: "Mint", color: .init(red: 0.2, green: 1, blue: 0.6)),
        LightSwatch(name: "Cyan", color: .init(red: 0, green: 0.9, blue: 1)),
        LightSwatch(name: "Blue", color: .init(red: 0.2, green: 0.4, blue: 1)),
        LightSwatch(name: "Purple", color: .init(red: 0.6, green: 0.1, blue: 1)),
        LightSwatch(name: "Pink", color: .init(red: 1, green: 0.2, blue: 0.7)),
        LightSwatch(name: "White", color: .init(red: 1, green: 1, blue: 1)),
    ]
}

// MARK: - Talking to the controller

/// A few DualSense calls have no explicit Swift name in Apple's SDK. Calling them through
/// their Objective-C selectors avoids depending on whatever name Swift generates for them.
@objc protocol DualSenseLegacyModes {
    @objc(setModeFeedbackWithStartPosition:resistiveStrength:)
    func dsFeedback(start: Float, strength: Float)

    @objc(setModeWeaponWithStartPosition:endPosition:resistiveStrength:)
    func dsWeapon(start: Float, end: Float, strength: Float)

    @objc(setModeVibrationWithStartPosition:amplitude:frequency:)
    func dsVibration(start: Float, amplitude: Float, frequency: Float)
}

extension GCDualSenseAdaptiveTrigger {
    var legacy: DualSenseLegacyModes { unsafeBitCast(self, to: DualSenseLegacyModes.self) }
}

enum TriggerWriter {
    static func apply(_ s: TriggerSettings, to t: GCDualSenseAdaptiveTrigger) {
        let start = Float(min(max(s.start, 0), 0.99))
        let end = Float(s.safeEnd)

        switch s.mode {
        case .off:
            t.setModeOff()
        case .resistance where s.resistanceEnd == nil:
            t.legacy.dsFeedback(start: start, strength: Float(s.strength))
        case .resistance:
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            writeFloats(s.zoneLevels.map { Float($0) }, into: &strengths.values)
            t.setModeFeedback(resistiveStrengths: strengths)
        case .twoStage:
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            let values: [Float] = (0..<10).map { i in
                let pos = Float(i) / 9
                if pos < start { return 0 }
                return pos < end ? Float(s.firstStrength) : Float(s.strength)
            }
            writeFloats(values, into: &strengths.values)
            t.setModeFeedback(resistiveStrengths: strengths)
        case .progressive:
            t.setModeSlopeFeedback(startPosition: start, endPosition: end,
                                   startStrength: Float(s.firstStrength), endStrength: Float(s.strength))
        case .click:
            t.legacy.dsWeapon(start: start, end: end, strength: Float(s.strength))
        case .rumble, .burst:
            rumble(s, on: t)
        case .custom where s.vibratesInCustom:
            // Apple's API has one amplitude for the whole range: use the strongest drawn zone.
            let levels = s.customLevels
            guard let first = levels.firstIndex(where: { $0 > 0.01 }) else { t.setModeOff(); return }
            t.legacy.dsVibration(start: Float(first) / 10, amplitude: Float(levels.max() ?? 0),
                                 frequency: Float(s.frequency))
        case .custom:
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            writeFloats(s.customLevels.map { Float($0) }, into: &strengths.values)
            t.setModeFeedback(resistiveStrengths: strengths)
        }
    }

    static func rumble(_ s: TriggerSettings, on t: GCDualSenseAdaptiveTrigger) {
        let start = Float(min(max(s.start, 0), 0.99))
        t.legacy.dsVibration(start: start, amplitude: Float(s.amplitude), frequency: Float(s.frequency))
    }

    /// Copies floats into a fixed-size C array (imported into Swift as a tuple).
    private static func writeFloats<T>(_ values: [Float], into tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { raw in
            let buffer = raw.bindMemory(to: Float.self)
            for i in 0..<min(buffer.count, values.count) {
                buffer[i] = min(max(values[i], 0), 1)
            }
        }
    }
}

// MARK: - Saved state

struct SavedState: Codable {
    var enabled = true
    var keepAlive = true
    var linked = false
    var left = TriggerSettings()
    var right = TriggerSettings()
    var selectedProfileID = "builtin.off"
    var customProfiles: [Profile] = []
    var lightOn = false
    var lightColor = LightColor()
    var lightEffect = LightEffect.solid
    var rainbowSpeed = 0.5
    var calibrationLeft = TriggerCalibration()
    var calibrationRight = TriggerCalibration()

    private static let key = "TriggerLab.state.v1"

    init() {}

    init(enabled: Bool, keepAlive: Bool, linked: Bool, left: TriggerSettings, right: TriggerSettings,
         selectedProfileID: String, customProfiles: [Profile], lightOn: Bool, lightColor: LightColor,
         lightEffect: LightEffect, rainbowSpeed: Double,
         calibrationLeft: TriggerCalibration, calibrationRight: TriggerCalibration) {
        self.enabled = enabled
        self.keepAlive = keepAlive
        self.linked = linked
        self.left = left
        self.right = right
        self.selectedProfileID = selectedProfileID
        self.customProfiles = customProfiles
        self.lightOn = lightOn
        self.lightColor = lightColor
        self.lightEffect = lightEffect
        self.rainbowSpeed = rainbowSpeed
        self.calibrationLeft = calibrationLeft
        self.calibrationRight = calibrationRight
    }

    // Tolerant decoding, so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? true
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked) ?? false
        left = try c.decodeIfPresent(TriggerSettings.self, forKey: .left) ?? TriggerSettings()
        right = try c.decodeIfPresent(TriggerSettings.self, forKey: .right) ?? TriggerSettings()
        selectedProfileID = try c.decodeIfPresent(String.self, forKey: .selectedProfileID) ?? "builtin.off"
        customProfiles = try c.decodeIfPresent([Profile].self, forKey: .customProfiles) ?? []
        lightOn = try c.decodeIfPresent(Bool.self, forKey: .lightOn) ?? false
        lightColor = try c.decodeIfPresent(LightColor.self, forKey: .lightColor) ?? LightColor()
        lightEffect = try c.decodeIfPresent(LightEffect.self, forKey: .lightEffect) ?? .solid
        rainbowSpeed = try c.decodeIfPresent(Double.self, forKey: .rainbowSpeed) ?? 0.5
        calibrationLeft = try c.decodeIfPresent(TriggerCalibration.self, forKey: .calibrationLeft) ?? TriggerCalibration()
        calibrationRight = try c.decodeIfPresent(TriggerCalibration.self, forKey: .calibrationRight) ?? TriggerCalibration()
    }

    static func load() -> SavedState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else {
            return SavedState()
        }
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: SavedState.key)
        }
    }
}
