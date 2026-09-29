import SwiftUI
import AppKit

@main
@MainActor
struct TriggerLabApp: App {
    @StateObject private var engine = TriggerEngine()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(engine)
        } label: {
            Image(systemName: engine.enabled ? "gamecontroller.fill" : "gamecontroller")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Main panel

/// Panel-only UI state. Kept in an ObservableObject instead of @State so the app
/// builds with just the Command Line Tools (newer SDKs implement @State as a macro,
/// which plain swiftc can't always load).
@MainActor
final class PanelUIState: ObservableObject {
    @Published var side: TriggerSide = .right
    @Published var naming = false
    @Published var newName = ""
    @Published var showWheel = false
    /// Measured height of the scrolling middle part of the panel.
    @Published var contentHeight: CGFloat = 0
}

/// Reports a view's height up to the panel, so the scroll area can size itself to its content.
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@MainActor
struct PanelView: View {
    @EnvironmentObject var engine: TriggerEngine
    @StateObject private var ui = PanelUIState()

    // The header and Quit button stay put; everything between them scrolls once the
    // panel would be taller than the screen.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            ScrollView(.vertical) {
                content
                    .padding(16)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
            }
            .frame(height: min(ui.contentHeight, maxContentHeight))
            .onPreferenceChange(ContentHeightKey.self) { ui.contentHeight = $0 }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let note = engine.connectionNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            profileSection
            Divider()
            sideSection
            TriggerEditor(settings: binding(for: ui.side),
                          live: engine.livePosition(ui.side),
                          calibrated: engine.isCalibrated(ui.side))
            Divider()
            lightSection
            Divider()
            keepAliveSection
            Divider()
            toolsSection
        }
    }

    /// Room left for the scrolling part: the screen's usable height minus the menu bar gap,
    /// header and footer.
    private var maxContentHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, screen - 150)
    }

    // Controller status and master switch
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(engine.isConnected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.controllerName ?? (engine.isConnected ? "DualSense" : "No DualSense connected"))
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Effects on", isOn: $engine.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Turn all trigger effects on or off")
        }
    }

    private var statusLine: String {
        guard engine.isConnected else { return "Pair it in System Settings, Bluetooth" }
        var parts: [String] = []
        if let level = engine.batteryLevel {
            parts.append("Battery \(Int((level * 100).rounded()))%" + (engine.isCharging ? ", charging" : ""))
        }
        parts.append(engine.enabled ? "Effects on" : "Effects paused")
        return parts.joined(separator: ". ")
    }

    // Profile picker and save actions
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    Section("Built-in") {
                        ForEach(Profile.builtIns) { p in
                            Button(p.name) { engine.select(p) }
                        }
                    }
                    if !engine.customProfiles.isEmpty {
                        Section("Your profiles") {
                            ForEach(engine.customProfiles) { p in
                                Button(p.name) { engine.select(p) }
                            }
                        }
                    }
                } label: {
                    Text(profileTitle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu("Save") {
                    Button("Save as new profile…") {
                        ui.newName = ""
                        ui.naming = true
                    }
                    if let p = engine.selectedProfile, !p.isBuiltIn {
                        Button("Update “\(p.name)”") { engine.updateSelectedProfile() }
                            .disabled(!engine.hasUnsavedEdits)
                        Divider()
                        Button("Delete “\(p.name)”", role: .destructive) { engine.deleteSelectedProfile() }
                    }
                }
                .fixedSize()
            }

            if ui.naming {
                HStack {
                    TextField("Profile name", text: $ui.newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveNew)
                    Button("Save", action: saveNew)
                        .disabled(ui.newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { ui.naming = false }
                }
            } else if let note = engine.selectedProfile?.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profileTitle: String {
        guard let p = engine.selectedProfile else { return "Custom settings" }
        return engine.hasUnsavedEdits ? "\(p.name) (edited)" : p.name
    }

    private func saveNew() {
        engine.saveNewProfile(named: ui.newName)
        ui.naming = false
    }

    // L2 / R2 switcher
    private var sideSection: some View {
        HStack {
            Picker("Trigger", selection: $ui.side) {
                ForEach(TriggerSide.allCases, id: \.self) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)

            Spacer()

            Toggle("Same on both", isOn: linkedBinding)
                .toggleStyle(.checkbox)
        }
    }

    private func binding(for side: TriggerSide) -> Binding<TriggerSettings> {
        let engine = engine
        return Binding(
            get: { engine.settings(for: side) },
            set: { engine.setSettings($0, for: side) } // the engine mirrors to the other side when linked
        )
    }

    private var linkedBinding: Binding<Bool> {
        let engine = engine
        let side = ui.side
        return Binding(
            get: { engine.linked },
            set: { engine.setLinked($0, copyingFrom: side) }
        )
    }

    // Light bar color
    private var lightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Set light bar color", isOn: $engine.lightOn)
                    .toggleStyle(.checkbox)
                Spacer()
                if engine.lightOn {
                    Picker("Light effect", selection: $engine.lightEffect) {
                        ForEach(LightEffect.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if engine.lightOn && engine.lightEffect == .rainbow {
                PercentSlider(title: "Rainbow speed", value: $engine.rainbowSpeed)
            }
            if engine.lightOn && engine.lightEffect == .solid {
                HStack(spacing: 7) {
                    ForEach(LightSwatch.all) { swatch in
                        let selected = engine.lightColor.sameHue(as: swatch.color)
                        Button {
                            var c = swatch.color
                            c.brightness = engine.lightColor.brightness
                            engine.lightColor = c
                        } label: {
                            Circle()
                                .fill(Color(red: swatch.color.red, green: swatch.color.green, blue: swatch.color.blue))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0.2),
                                                    lineWidth: selected ? 2 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                        .accessibilityLabel(swatch.name)
                    }
                    Button {
                        ui.showWheel.toggle()
                    } label: {
                        Circle()
                            .fill(AngularGradient(gradient: ColorWheel.hueGradient, center: .center))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.primary.opacity(ui.showWheel ? 0.9 : 0.2),
                                                     lineWidth: ui.showWheel ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("Custom color")
                    .accessibilityLabel("Custom color")
                }
                if ui.showWheel {
                    HStack {
                        Spacer()
                        ColorWheel(color: $engine.lightColor)
                        Spacer()
                    }
                }
            }
            if engine.lightOn {
                PercentSlider(title: "Brightness", value: $engine.lightColor.brightness)
            }
        }
    }

    // Input diagnostics and calibration
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Diagnostics and calibration", isOn: $engine.debugOn)
                .toggleStyle(.checkbox)
            if engine.debugOn {
                DiagnosticsView(side: ui.side)
                CalibrationView(side: ui.side)
            }
        }
    }

    private var keepAliveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep effects applied", isOn: $engine.keepAlive)
                .toggleStyle(.checkbox)
            Text("Re-sends your settings every couple of seconds, in case a game or Steam resets the triggers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit Trigger Lab") {
                engine.shutdown()
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Editor for one trigger

struct TriggerEditor: View {
    @Binding var settings: TriggerSettings
    var live: Double
    var calibrated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: modeBinding) {
                ForEach(TriggerMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Text(settings.mode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TravelGraph(settings: settings, live: live, calibrated: calibrated,
                        onDraw: settings.mode == .custom ? { zone, value in
                            settings.customLevels[zone] = value
                        } : nil)

            if settings.mode == .custom {
                customControls
            }
            if settings.mode != .off && settings.mode != .custom {
                PercentSlider(title: "Starts at", value: $settings.start, step: 0.1)
            }
            if settings.mode.usesEnd {
                PercentSlider(title: settings.mode.endTitle,
                              value: settings.mode == .resistance ? $settings.resistanceStop : $settings.end,
                              step: 0.1)
            }
            if settings.mode.usesFirstStrength {
                PercentSlider(title: settings.mode.firstStrengthTitle, value: $settings.firstStrength)
            }
            if settings.mode.usesStrength {
                PercentSlider(title: settings.mode.strengthTitle, value: $settings.strength)
            }
            if settings.mode.usesRumble {
                PercentSlider(title: "Rumble strength", value: $settings.amplitude)
                PercentSlider(title: "Rumble speed", value: $settings.frequency)
            }
            if settings.mode.usesBurst {
                MillisecondSlider(title: "Buzz for", value: $settings.burstOnMs)
                MillisecondSlider(title: "Pause for", value: $settings.burstOffMs)
            }
        }
    }

    /// Switching to Custom for the first time starts from the current mode's shape,
    /// so you can tweak a preset instead of drawing from scratch.
    private var modeBinding: Binding<TriggerMode> {
        let current = $settings
        return Binding(
            get: { current.wrappedValue.mode },
            set: { mode in
                var s = current.wrappedValue
                if mode == .custom && s.customZones == nil {
                    s.customLevels = s.zoneLevels.map { ($0 * 8).rounded() / 8 }
                    s.customVibrates = s.isRumble
                }
                s.mode = mode
                current.wrappedValue = s
            }
        )
    }

    @ViewBuilder private var customControls: some View {
        Picker("Effect", selection: $settings.vibratesInCustom) {
            Text("Resistance").tag(false)
            Text("Vibration").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        HStack(spacing: 6) {
            Text("Shapes").font(.caption).foregroundStyle(.secondary)
            Button("Flat") { settings.customLevels = Array(repeating: 0.5, count: 10) }
            Button("Ramp") { settings.customLevels = (0..<10).map { (Double($0 + 1) * 0.8).rounded() / 8 } }
            Button("Wall") { settings.customLevels = (0..<10).map { $0 >= 5 ? 1 : 0 } }
            Button("Bumps") { settings.customLevels = (0..<10).map { $0 % 3 == 2 ? 1 : 0.125 } }
            Button("Clear") { settings.customLevels = Array(repeating: 0, count: 10) }
        }
        .font(.caption)
        .controlSize(.small)

        if settings.vibratesInCustom {
            PercentSlider(title: "Vibration speed", value: $settings.frequency)
        }
    }
}

/// Shows how the trigger will feel across its travel, with a live readout of how far it's pressed.
struct TravelGraph: View {
    let settings: TriggerSettings
    /// How far the trigger is pressed, in the graph's zone scale (0...1).
    let live: Double
    let calibrated: Bool
    /// When set, dragging on the graph draws zone levels (Custom mode): zone 0...9, level 0...1.
    var onDraw: ((Int, Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                canvas
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        guard let onDraw, geo.size.width > 0, geo.size.height > 0 else { return }
                        let zone = min(9, max(0, Int(v.location.x / geo.size.width * 10)))
                        let raw = 1 - v.location.y / geo.size.height
                        // Snap to the controller's 8 strength steps; the bottom sliver means none.
                        let level = min(1, max(0, (raw * 8).rounded() / 8))
                        onDraw(zone, level)
                    })
            }
            .frame(height: onDraw == nil ? 44 : 80)
            .accessibilityLabel(onDraw == nil ? "Trigger feel preview" : "Trigger feel editor. Drag to draw each zone.")

            HStack {
                Text("Released")
                Spacer()
                Text("Pressed \(Int((live * 100).rounded()))%" + (calibrated ? " (calibrated)" : ""))
                Spacer()
                Text("Fully pressed")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var canvas: some View {
        Canvas { context, size in
            // One bar per zone while editing, so each bar is something you can grab.
            let count = onDraw == nil ? 48 : 10
            let gap: CGFloat = 1.5
            let barWidth = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let pressed = live
            let effectColor: Color = settings.isRumble ? .orange : .accentColor
            let levels = settings.zoneLevels

            for i in 0..<count {
                let pos = (Double(i) + 0.5) / Double(count)
                var level = levels[min(9, Int(pos * 10))]
                if settings.isRumble && onDraw == nil && level > 0 && i % 2 == 1 {
                    level *= 0.55 // zigzag to hint at vibration
                }
                let height = max(3, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(i) * (barWidth + gap),
                                  y: size.height - height,
                                  width: barWidth,
                                  height: height)
                let isPressed = pos <= pressed
                let color: Color
                if level == 0 {
                    color = Color.secondary.opacity(isPressed ? 0.45 : 0.15)
                } else {
                    color = effectColor.opacity(isPressed ? 1.0 : 0.4)
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
            }
        }
    }
}

// MARK: - Color wheel

/// Hue around the edge, saturation from the white center outwards. Drag to pick.
struct ColorWheel: View {
    @Binding var color: LightColor
    var size: CGFloat = 130

    static let hueGradient = Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    })

    var body: some View {
        let radius = size / 2
        let hs = color.hueSaturation
        let angle = hs.hue * 2 * .pi
        let knob = CGPoint(x: radius + cos(angle) * hs.saturation * radius,
                           y: radius + sin(angle) * hs.saturation * radius)
        return ZStack {
            Circle().fill(AngularGradient(gradient: ColorWheel.hueGradient, center: .center))
            Circle().fill(RadialGradient(gradient: Gradient(colors: [.white, .white.opacity(0)]),
                                         center: .center, startRadius: 0, endRadius: radius))
            Circle()
                .fill(Color(red: color.red, green: color.green, blue: color.blue))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(radius: 1)
                .position(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let dx = v.location.x - radius, dy = v.location.y - radius
            // Angles grow clockwise here (y points down), matching the angular gradient.
            var hue = atan2(dy, dx) / (2 * .pi)
            if hue < 0 { hue += 1 }
            let saturation = min(1, (dx * dx + dy * dy).squareRoot() / radius)
            color = LightColor(hue: hue, saturation: saturation, brightness: color.brightness)
        })
        .accessibilityLabel("Color wheel")
    }
}

// MARK: - Diagnostics

/// Shows where live trigger values come from, and the raw bytes they're read from.
struct DiagnosticsView: View {
    @EnvironmentObject var engine: TriggerEngine
    let side: TriggerSide

    var body: some View {
        let snap = engine.debugSnapshot
        VStack(alignment: .leading, spacing: 3) {
            line("Live source", engine.liveSource)
            line("Input Monitoring", engine.inputMonitoring)
            line("Last output", engine.lastOutput)
            if let snap {
                line("Report", String(format: "0x%02X, %d bytes, ID byte %@, %d/s",
                                      snap.reportID, snap.length,
                                      snap.idIncluded ? "included" : "not included", engine.reportRate))
                line("L2", "HID \(value(snap.l2)) · GameController \(percent(engine.gcLeft))")
                line("R2", "HID \(value(snap.r2)) · GameController \(percent(engine.gcRight))")
                line("Bytes 0-11", hex(snap.payload.prefix(12)))
                if snap.layoutStart != nil {
                    line("Motor R2 0x29", motor(snap.motorByte(.right)))
                    line("Motor L2 0x2A", motor(snap.motorByte(.left)))
                    line("Effect 0x2F", snap.effectByte.map { String(format: "%02X", $0) } ?? "-")
                } else {
                    line("Motor", "not in the basic Bluetooth report")
                }
            } else {
                line("Report", "no HID input reports received yet")
                line("L2 / R2", "GameController \(percent(engine.gcLeft)) / \(percent(engine.gcRight))")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func value(_ b: UInt8?) -> String {
        guard let b else { return "-" }
        return "\(b) (\(Int((Double(b) / 255 * 100).rounded()))%)"
    }

    private func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Low 4 bits "stop location", high 4 bits "status" (unverified community layout).
    private func motor(_ b: UInt8?) -> String {
        guard let b else { return "-" }
        return String(format: "%02X  stop %d, status %d", b, b & 0x0F, b >> 4)
    }
}

// MARK: - Calibration

struct CalibrationView: View {
    @EnvironmentObject var engine: TriggerEngine
    let side: TriggerSide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibrate \(side.label)")
                .font(.callout.weight(.semibold))
            if let run = engine.calibrationRun {
                runView(run)
            } else {
                if !engine.canCalibrate {
                    Text("Needs the controller connected with HID input working (see Live source above).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(EffectFamily.allCases) { family in
                    familyRow(family)
                }
                Button("Copy \(side.label) calibration to \(side == .left ? "R2" : "L2")") {
                    engine.copyCalibration(from: side)
                }
                .font(.caption)
            }
        }
    }

    private func familyRow(_ family: EffectFamily) -> some View {
        let points = engine.calibration(for: side).points(for: family)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(family.title).font(.caption)
                Spacer()
                if !points.isEmpty {
                    Button("Clear") { engine.clearCalibration(side: side, family: family) }
                        .font(.caption)
                }
                Button(points.isEmpty ? "Calibrate" : "Redo") {
                    engine.startCalibration(side: side, family: family)
                }
                .font(.caption)
                .disabled(!engine.canCalibrate)
            }
            Text(points.isEmpty ? "Not calibrated" : summary(points))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// "zone 2 at 14% (motor 32)" for each point, i.e. where the zone was felt.
    private func summary(_ points: [CalibrationPoint]) -> String {
        points.map { p in
            let motor = p.motor.map { String(format: " m%02X", $0) } ?? ""
            return "z\(p.zone) \(Int((p.analog * 100).rounded()))%\(motor)"
        }.joined(separator: " · ")
    }

    private func runView(_ run: CalibrationRun) -> some View {
        let raw = run.side == .left ? engine.liveLeft : engine.liveRight
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(run.family.title): step \(run.step + 1) of \(run.family.testZones.count)")
                .font(.caption.weight(.medium))
            Text("\(run.family == .vibration ? "Buzzing" : "A hard wall") starts at zone \(run.zone) (\(run.zone * 10)% on the graph). \(run.family.instruction)")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(run.side.label) reads \(Int((Double(raw) * 100).rounded()))% right now")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack {
                Button("Record") { engine.recordCalibrationPoint() }
                    .keyboardShortcut(.defaultAction)
                Button("Back") { engine.redoCalibrationStep() }
                    .disabled(run.recorded.isEmpty)
                Spacer()
                Button("Cancel") { engine.cancelCalibration() }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
    }
}

struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    var step: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            if let step {
                Slider(value: $value, in: 0...1, step: step)
            } else {
                Slider(value: $value, in: 0...1)
            }
        }
    }
}

struct MillisecondSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value)) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: 30...400, step: 10)
        }
    }
}
