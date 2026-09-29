import Foundation
import AppKit
import GameController

@MainActor
final class TriggerEngine: ObservableObject {
    // Controller status
    @Published private(set) var controllerName: String?
    @Published private(set) var batteryLevel: Float?
    @Published private(set) var isCharging = false
    @Published private(set) var liveLeft: Float = 0
    @Published private(set) var liveRight: Float = 0
    @Published private(set) var connectionNote: String?

    // Diagnostics: GameController's values (kept even when HID is the live source, to compare)
    // and the latest raw HID report, refreshed while the diagnostics panel is open.
    @Published private(set) var gcLeft: Float = 0
    @Published private(set) var gcRight: Float = 0
    @Published private(set) var debugSnapshot: HIDInputSnapshot?
    @Published private(set) var reportRate = 0
    @Published var debugOn = false {
        didSet { if debugOn != oldValue { updateDebugTimer() } }
    }

    // Calibration
    @Published private(set) var calibrationLeft: TriggerCalibration { didSet { persist() } }
    @Published private(set) var calibrationRight: TriggerCalibration { didSet { persist() } }
    @Published private(set) var calibrationRun: CalibrationRun?

    // Settings
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            persist()
            if enabled { applyAll(); restartBursts() } else { releaseTriggers() }
        }
    }
    @Published var keepAlive: Bool { didSet { persist() } }

    @Published var left: TriggerSettings {
        didSet {
            guard left != oldValue else { return }
            if linked && !syncing && right != left {
                syncing = true
                right = left
                syncing = false
            }
            settingsChanged(side: .left, old: oldValue)
        }
    }
    @Published var right: TriggerSettings {
        didSet {
            guard right != oldValue else { return }
            if linked && !syncing && left != right {
                syncing = true
                left = right
                syncing = false
            }
            settingsChanged(side: .right, old: oldValue)
        }
    }
    @Published private(set) var linked: Bool { didSet { persist() } }

    @Published var lightOn: Bool {
        didSet {
            guard lightOn != oldValue else { return }
            persist()
            applyAll()
            updateRainbow()
        }
    }
    @Published var lightEffect: LightEffect {
        didSet {
            guard lightEffect != oldValue else { return }
            persist()
            applyAll()
            updateRainbow()
        }
    }
    /// 0 = slow (one cycle in 20 s), 1 = fast (one cycle in 2 s).
    @Published var rainbowSpeed: Double { didSet { if rainbowSpeed != oldValue { persist() } } }
    @Published var lightColor: LightColor {
        didSet {
            guard lightColor != oldValue else { return }
            persist()
            applyAll()
        }
    }

    @Published private(set) var customProfiles: [Profile] { didSet { persist() } }
    @Published private(set) var selectedProfileID: String { didSet { persist() } }

    private let hid = DualSenseHID()
    private var controller: GCController?
    private var pad: GCDualSenseGamepad?
    private var burstTasks: [TriggerSide: Task<Void, Never>] = [:]
    private var housekeeping: Timer?
    private var observers: [NSObjectProtocol] = []
    private var syncing = false
    private var debugTimer: Timer?
    private var rainbowTimer: Timer?
    private var rainbowPhase = 0.0
    private var rainbowLastTick = 0.0
    private var rateSample = (count: 0, time: 0.0)

    init() {
        let saved = SavedState.load()
        enabled = saved.enabled
        keepAlive = saved.keepAlive
        linked = saved.linked
        left = saved.left
        right = saved.right
        lightOn = saved.lightOn
        lightColor = saved.lightColor
        lightEffect = saved.lightEffect
        rainbowSpeed = saved.rainbowSpeed
        customProfiles = saved.customProfiles
        selectedProfileID = saved.selectedProfileID
        calibrationLeft = saved.calibrationLeft
        calibrationRight = saved.calibrationRight

        // Keep reading trigger presses while a game is the frontmost app.
        GCController.shouldMonitorBackgroundEvents = true

        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.findController() }
            })
        }

        // Quitting any way (Quit button, Dock, or a script) resets the triggers and stops the rainbow.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        })

        // Raw trigger positions straight from the controller (no dead zone).
        hid.onTriggers = { [weak self] l, r in
            Task { @MainActor in
                guard let self else { return }
                self.liveLeft = l
                self.liveRight = r
            }
        }
        hid.onCross = { [weak self] in
            Task { @MainActor in self?.recordCalibrationPoint() }
        }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeeping = timer

        findController()
        refreshConnectionNote()
        applyAll()
        restartBursts()
        updateRainbow()
    }

    // MARK: Status

    var isConnected: Bool { controllerName != nil || hid.hasDevice }

    var allProfiles: [Profile] { Profile.builtIns + customProfiles }

    var selectedProfile: Profile? { allProfiles.first { $0.id == selectedProfileID } }

    var hasUnsavedEdits: Bool {
        guard let p = selectedProfile else { return true }
        return p.left != left || p.right != right
    }

    func settings(for side: TriggerSide) -> TriggerSettings {
        side == .left ? left : right
    }

    func setSettings(_ s: TriggerSettings, for side: TriggerSide) {
        if side == .left { left = s } else { right = s }
    }

    /// Turns "same on both" on or off. When turning on, copies the trigger you're editing to the other one.
    func setLinked(_ on: Bool, copyingFrom side: TriggerSide) {
        guard on != linked else { return }
        linked = on
        if on {
            let s = settings(for: side)
            syncing = true
            left = s
            right = s
            syncing = false
        }
    }

    // MARK: Profiles

    func select(_ profile: Profile) {
        syncing = true
        left = profile.left
        right = profile.right
        syncing = false
        selectedProfileID = profile.id
        if profile.left != profile.right { linked = false }
    }

    func saveNewProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let profile = Profile(id: "custom.\(UUID().uuidString)", name: trimmed, note: "",
                              left: left, right: right)
        customProfiles.append(profile)
        selectedProfileID = profile.id
    }

    func updateSelectedProfile() {
        guard let i = customProfiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        customProfiles[i].left = left
        customProfiles[i].right = right
    }

    func deleteSelectedProfile() {
        guard selectedProfile?.isBuiltIn == false else { return }
        customProfiles.removeAll { $0.id == selectedProfileID }
        selectedProfileID = ""
    }

    /// Turns the effects off before quitting so the controller isn't left stiff.
    func shutdown() {
        housekeeping?.invalidate()
        rainbowTimer?.invalidate()
        releaseTriggers()
    }

    // MARK: Live position and diagnostics

    func calibration(for side: TriggerSide) -> TriggerCalibration {
        side == .left ? calibrationLeft : calibrationRight
    }

    /// How far the trigger is pressed, in the graph's zone scale (0...1) for the trigger's
    /// current mode, using that mode's calibration if there is one.
    func livePosition(_ side: TriggerSide) -> Double {
        let raw = Double(side == .left ? liveLeft : liveRight)
        return calibration(for: side).position(analog: raw, family: settings(for: side).family)
    }

    func isCalibrated(_ side: TriggerSide) -> Bool {
        guard let family = settings(for: side).family else { return false }
        return !calibration(for: side).points(for: family).isEmpty
    }

    var liveSource: String {
        if hid.inputIsLive, let kind = hid.latest?.kind { return "HID input report, \(kind.rawValue)" }
        if pad != nil { return "GameController fallback (no HID input reports)" }
        return "None"
    }

    var inputMonitoring: String { hid.accessDescription }

    var lastOutput: String {
        guard let r = hid.lastSendResult else { return "nothing sent yet" }
        return r == kIOReturnSuccess ? "sent OK" : String(format: "failed (0x%08X)", UInt32(bitPattern: r))
    }

    private func updateDebugTimer() {
        debugTimer?.invalidate()
        debugTimer = nil
        guard debugOn else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDebug() }
        }
        RunLoop.main.add(timer, forMode: .common)
        debugTimer = timer
        refreshDebug()
    }

    private func refreshDebug() {
        debugSnapshot = hid.latest
        let now = ProcessInfo.processInfo.systemUptime
        if now - rateSample.time >= 1 {
            reportRate = rateSample.time == 0 ? 0 : Int(Double(hid.reportCount - rateSample.count) / (now - rateSample.time))
            rateSample = (hid.reportCount, now)
        }
    }

    // MARK: Calibration

    /// Calibration needs raw effects and raw input, so it only works over HID.
    var canCalibrate: Bool { hid.hasDevice && hid.inputIsLive }

    /// Sets a full-strength wall at a few zones in turn; you press until you feel it and the
    /// analog value at that moment is recorded for that zone.
    func startCalibration(side: TriggerSide, family: EffectFamily) {
        guard canCalibrate else { return }
        calibrationRun = CalibrationRun(side: side, family: family)
        applyAll()
        restartBursts()
    }

    func recordCalibrationPoint() {
        guard var run = calibrationRun, let snapshot = hid.latest, hid.inputIsLive,
              let raw = run.side == .left ? snapshot.l2 : snapshot.r2 else { return }
        run.recorded.append(CalibrationPoint(zone: run.zone, analog: Double(raw) / 255,
                                             motor: snapshot.motorByte(run.side)))
        if run.recorded.count < run.family.testZones.count {
            calibrationRun = run
            applyAll()
            return
        }
        if run.side == .left {
            calibrationLeft.setPoints(run.recorded, for: run.family)
        } else {
            calibrationRight.setPoints(run.recorded, for: run.family)
        }
        endCalibration(side: run.side)
    }

    func redoCalibrationStep() {
        guard var run = calibrationRun, !run.recorded.isEmpty else { return }
        run.recorded.removeLast()
        calibrationRun = run
        applyAll()
    }

    func cancelCalibration() {
        guard let run = calibrationRun else { return }
        endCalibration(side: run.side)
    }

    func clearCalibration(side: TriggerSide, family: EffectFamily) {
        if side == .left { calibrationLeft.setPoints([], for: family) }
        else { calibrationRight.setPoints([], for: family) }
    }

    func copyCalibration(from side: TriggerSide) {
        if side == .left { calibrationRight = calibrationLeft } else { calibrationLeft = calibrationRight }
    }

    /// Removes the test wall and puts the trigger's own effect back.
    private func endCalibration(side: TriggerSide) {
        calibrationRun = nil
        send(TriggerEffect.off(), to: side)
        applyAll()
        restartBursts()
    }

    // MARK: Controller

    private func findController() {
        let found = GCController.controllers().first { $0.extendedGamepad is GCDualSenseGamepad }
        if found === controller {
            refreshBattery()
            return
        }

        controller = found
        pad = found?.extendedGamepad as? GCDualSenseGamepad
        controllerName = found.map { $0.vendorName ?? "DualSense" }

        // Apple's values are only a fallback: they have a dead zone at the start of the pull.
        // They're used only while no HID input reports are arriving.
        if let pad {
            pad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.gcLeft = value
                    if !self.hid.inputIsLive { self.liveLeft = value }
                }
            }
            pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.gcRight = value
                    if !self.hid.inputIsLive { self.liveRight = value }
                }
            }
        }
        applyAll()
        restartBursts()
        refreshBattery()
        refreshConnectionNote()
    }

    private func refreshBattery() {
        guard let battery = controller?.battery else {
            batteryLevel = nil
            isCharging = false
            return
        }
        batteryLevel = battery.batteryLevel
        isCharging = battery.batteryState == .charging
    }

    private func refreshConnectionNote() {
        switch hid.status {
        case .noAccess:
            connectionNote = "Allow Trigger Lab in System Settings, Privacy & Security, Input Monitoring, then reopen it."
        case .failed(let code):
            connectionNote = "Couldn't open the controller directly (error \(code)). Using Apple's controller API instead."
        case .ready:
            if let how = hid.connection {
                connectionNote = "Connected directly over \(how)."
            } else {
                connectionNote = nil
            }
        }
    }

    private func tick() {
        if pad == nil { findController() }
        refreshBattery()
        refreshConnectionNote()
        // Some games (and Steam Input) reset the triggers. Re-sending keeps our effect on.
        if keepAlive { applyAll() }
    }

    private func trigger(_ side: TriggerSide, on pad: GCDualSenseGamepad) -> GCDualSenseAdaptiveTrigger {
        side == .left ? pad.leftTrigger : pad.rightTrigger
    }

    // MARK: Applying effects

    private func settingsChanged(side: TriggerSide, old: TriggerSettings) {
        persist()
        guard enabled else { return }
        // Switching a trigger to Off releases it once; after that it's left alone.
        if settings(for: side).mode == .off && old.mode != .off {
            send(TriggerEffect.off(), to: side)
        }
        applyAll()
        restartBursts()
    }

    /// Sends everything that should currently be active: trigger effects (unless Off or Burst)
    /// and the light bar color.
    private func applyAll() {
        let l = enabled && left.mode != .off && left.mode != .burst ? left : nil
        let r = enabled && right.mode != .off && right.mode != .burst ? right : nil

        if hid.hasDevice {
            // A running calibration replaces that trigger's effect with its test wall.
            func effect(_ side: TriggerSide, _ s: TriggerSettings?) -> [UInt8]? {
                if let run = calibrationRun, run.side == side { return run.effect }
                return s.map(TriggerEffect.from)
            }
            hid.send(left: effect(.left, l),
                     right: effect(.right, r),
                     light: lightOn ? currentLightBytes() : nil)
        } else if let pad {
            if let l { TriggerWriter.apply(l, to: pad.leftTrigger) }
            if let r { TriggerWriter.apply(r, to: pad.rightTrigger) }
            if lightOn, let light = controller?.light {
                let b = currentLightBytes().map { Float($0) / 255 }
                light.color = GCColor(red: b[0], green: b[1], blue: b[2])
            }
        }
    }

    private func send(_ effect: [UInt8], to side: TriggerSide) {
        if hid.hasDevice {
            hid.send(left: side == .left ? effect : nil, right: side == .right ? effect : nil)
        } else if let pad {
            trigger(side, on: pad).setModeOff()
        }
    }

    /// Burst: while the trigger is held past its start point, the rumble switches on and off
    /// in a rhythm. While it's released, the rumble effect just sits ready, so nothing buzzes.
    private func restartBursts() {
        for task in burstTasks.values { task.cancel() }
        burstTasks = [:]
        guard enabled, pad != nil || hid.hasDevice else { return }

        for side in TriggerSide.allCases where settings(for: side).mode == .burst && calibrationRun?.side != side {
            burstTasks[side] = Task { [weak self] in
                var rumbling = false
                var primed = false
                while !Task.isCancelled {
                    guard let self else { return }
                    let s = self.settings(for: side)
                    guard s.mode == .burst, self.enabled, self.calibrationRun?.side != side else { return }

                    let live = self.livePosition(side)
                    let threshold = max(0.04, Double(s.startZone) / 10)
                    let held = live >= threshold

                    if !held {
                        if !primed {
                            self.sendRumble(s, side: side, on: true)
                            primed = true
                            rumbling = true
                        }
                        try? await Task.sleep(nanoseconds: 15_000_000)
                        continue
                    }

                    primed = false
                    if rumbling {
                        try? await Task.sleep(nanoseconds: UInt64(max(20, s.burstOnMs) * 1_000_000))
                        self.sendRumble(s, side: side, on: false)
                        rumbling = false
                    } else {
                        try? await Task.sleep(nanoseconds: UInt64(max(20, s.burstOffMs) * 1_000_000))
                        self.sendRumble(s, side: side, on: true)
                        rumbling = true
                    }
                }
            }
        }
    }

    private func sendRumble(_ s: TriggerSettings, side: TriggerSide, on: Bool) {
        if hid.hasDevice {
            send(on ? TriggerEffect.rumbleOn(s) : TriggerEffect.off(), to: side)
        } else if let pad {
            let t = trigger(side, on: pad)
            if on { TriggerWriter.rumble(s, on: t) } else { t.setModeOff() }
        }
    }

    // MARK: Light bar

    /// The color the light bar should show right now (rainbow moves with time).
    private func currentLightBytes() -> [UInt8] {
        guard lightEffect == .rainbow else { return lightColor.bytes }
        return LightColor(hue: rainbowPhase, saturation: 1, brightness: lightColor.brightness).bytes
    }

    /// Runs the rainbow animation while it's switched on: sends only the light bar color,
    /// about 30 times a second, so trigger effects are left alone.
    private func updateRainbow() {
        let wanted = lightOn && lightEffect == .rainbow
        guard wanted != (rainbowTimer != nil) else { return }
        rainbowTimer?.invalidate()
        rainbowTimer = nil
        guard wanted else { return }
        rainbowLastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rainbowTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rainbowTimer = timer
    }

    private func rainbowTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let period = 20 - 18 * min(max(rainbowSpeed, 0), 1) // seconds per full cycle
        rainbowPhase = (rainbowPhase + (now - rainbowLastTick) / period).truncatingRemainder(dividingBy: 1)
        rainbowLastTick = now

        let bytes = currentLightBytes()
        if hid.hasDevice {
            hid.send(left: nil, right: nil, light: bytes)
        } else if let light = controller?.light {
            light.color = GCColor(red: Float(bytes[0]) / 255, green: Float(bytes[1]) / 255, blue: Float(bytes[2]) / 255)
        }
    }

    private func releaseTriggers() {
        calibrationRun = nil
        for task in burstTasks.values { task.cancel() }
        burstTasks = [:]
        if hid.hasDevice {
            hid.send(left: TriggerEffect.off(), right: TriggerEffect.off())
        }
        pad?.leftTrigger.setModeOff()
        pad?.rightTrigger.setModeOff()
    }

    private func persist() {
        SavedState(enabled: enabled, keepAlive: keepAlive, linked: linked, left: left, right: right,
                   selectedProfileID: selectedProfileID, customProfiles: customProfiles,
                   lightOn: lightOn, lightColor: lightColor,
                   lightEffect: lightEffect, rainbowSpeed: rainbowSpeed,
                   calibrationLeft: calibrationLeft, calibrationRight: calibrationRight).save()
    }
}

/// One calibration pass: one trigger, one effect type, one test zone at a time.
struct CalibrationRun: Equatable {
    let side: TriggerSide
    let family: EffectFamily
    var recorded: [CalibrationPoint] = []

    var step: Int { recorded.count }
    var zone: Int { family.testZones[min(step, family.testZones.count - 1)] }
    var effect: [UInt8] { family.testEffect(zone: zone) }
}
