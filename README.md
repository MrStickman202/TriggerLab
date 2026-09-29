# Trigger Lab

A menu bar app that turns on DualSense adaptive trigger effects on your Mac,
for any game, even ones that don't support them.

## Build it (one time)

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
