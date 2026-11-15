# Trigger Lab

A menu bar app that turns on DualSense adaptive trigger effects on your Mac,
for any game, even ones that don't support them.

## Download

1. Download **TriggerLab.dmg** from the
   [latest release](https://github.com/MrStickman202/TriggerLab/releases/latest) and open it.
   (TriggerLab.zip has the same app, if you prefer a zip.)
2. Drag **Trigger Lab** onto the Applications folder, then open it from Applications.
   It runs on Apple Silicon and Intel Macs with macOS 13 or later.
3. The app isn't signed with an Apple developer account, so macOS blocks it the first
   time. Open System Settings > Privacy & Security, scroll down, and click
   **Open Anyway** next to the message about Trigger Lab. Or run this once in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/Trigger Lab.app"`

## Or build it yourself

1. If you've never used Swift on this Mac, install Apple's command line tools:
   `xcode-select --install`
2. Open Terminal in this folder and run: `bash build.sh`
3. Drag **Trigger Lab.app** into Applications and open it. A controller icon
   appears in the menu bar. Click it to open the panel.

## Using it

- Pick a built-in profile (Pistol, Bow, Racing, Minecraft…) or build your own.
- Changes apply instantly, no need to save.
- The trigger's travel is split into 10 steps by the controller, so the start and
  end sliders move in 10% steps. The graph shows exactly what gets sent.
- "Set light bar color" changes the controller's light: pick a swatch, the rainbow
  swatch for a color wheel, or Rainbow to cycle smoothly through colors. It works
  even when the trigger effects are switched off.
- Switch between L2 and R2 to edit each trigger. "Same on both" mirrors them.
- The graph shows how the trigger will feel along its travel. Press the trigger
  while the panel is open to see where you are.
- Save your own setups with **Save > Save as new profile**.
- The switch at the top turns every effect on or off.
- Quit from the panel so the triggers are reset to normal.
- Right-click the menu bar icon (or use the button at the bottom of the panel) for
  **Check for Updates**. It compares your version with the newest release here.

## Modes

- **Resistance**: same stiffness from the start point down.
- **Two-stage**: light first stage, harder second stage.
- **Progressive**: gets stiffer the further you press.
- **Click**: resistance that breaks at the end point, like a gun trigger.
- **Rumble**: the trigger buzzes once pressed past the start point.
- **Off**: leaves the trigger alone, so a game or mod (like Controlify) can use its own effects.
- **Burst**: rumble in on/off pulses while you hold the trigger, with adjustable timing.
- **Custom**: draw your own. Drag on the graph to set each of the 10 zones, and pick
  resistance or vibration. It starts from whatever mode you were on.

## Diagnostics and calibration

Tick "Diagnostics and calibration" in the panel to see where the live trigger
value comes from (HID input or Apple's GameController fallback) and the raw report
bytes. Calibration sets a hard wall at a few zones for the selected trigger; press
until you feel it and press ✕ (or Record). The graph's live marker then lines up
with where you actually feel each effect. Each effect type (resistance, click,
rumble) is calibrated separately.

## Minecraft with Controlify

Controlify has its own DualSense trigger effects. Use one or the other:
either turn off trigger effects in Controlify's controller settings and use the
"Minecraft (Controlify)" profile here, or set this app's triggers to Off and let
Controlify handle them. If the light bar flickers between colors, Controlify is
setting its own color too; turn one of them off.

## Horizon over Bluetooth

[Horizon](https://github.com/horizon-rust/horizon) (Minecraft: Java Edition rewritten in Rust)
sees a Bluetooth DualSense on a Mac as connected but reads none of its buttons. Tick
**Play Horizon over Bluetooth** and Trigger Lab passes the buttons, sticks and triggers to
the game, which then plays them like any controller (same bindings, same Controller
Settings). Trigger effects and the light bar keep working at the same time.

- The line under the switch says what it's doing. "Horizon not found" means the game
  isn't running, or Agent Control is off in Horizon Settings > Extras.
- "Only while Horizon is in front" stops the controller moving your character while
  you're in another app.
- Over a USB cable Horizon reads the controller by itself, so nothing is passed on.
- If the controller tips flicker and sprint cancels, the mouse or trackpad moved:
  Horizon hands control back to the mouse whenever it moves.
- Don't run the separate DualSense Bridge app at the same time: every move would
  be sent twice.

## If something's off

- The first time you open it, macOS may ask to allow Trigger Lab under
  Privacy & Security > Input Monitoring. Allow it, then quit and reopen the app.
  Rebuilding the app can reset this permission, so you may need to allow it again.

- Nothing happens: make sure the controller shows as connected in the panel.
  If it's on Bluetooth, try a USB cable.
- Effects keep disappearing: leave "Keep effects applied" on. If you use
  Steam, its controller settings can reset the triggers.
- A game has its own adaptive trigger support: turn Trigger Lab off for that
  game so the two don't fight.
- The effects are the same all the time. The app can't see what's happening
  in the game, so pick a profile that fits the game you're playing.
