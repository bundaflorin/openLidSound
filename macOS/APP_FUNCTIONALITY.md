# Open Lid Sound: Functionality and How It Works

## What This App Does

Open Lid Sound is a macOS background app that reacts to system sleep and wake power events.

It plays:
- a **close sound** when the Mac is about to sleep (commonly when the lid is closed)
- an **open sound** when the Mac wakes (commonly when the lid is opened)

The app also provides a small settings window so you can choose which file to use as the open-lid sound.

## Main Features

  - Open Settings
  - Quit Open Lid Sound

## Menu Bar Only (No Dock) Behavior

Open Lid Sound is designed to run only in the menu bar and not appear in the Dock or app switcher. This is achieved by:

- Setting `LSUIElement` to `true` in the app's `Info.plist`.
- Setting the activation policy in code to `.accessory`:

  ```swift
  app.setActivationPolicy(.accessory)
  ```

This ensures the app is a background agent with a menu bar item, and never appears in the Dock or ⌘-Tab app switcher.

## Supported Sound Files

The app scans the `sound_effects/` directory for these extensions:

- `.aif`
- `.aiff`
- `.caf`
- `.m4a`
- `.mp3`
- `.wav`

If no custom open sound is selected, it falls back to a system sound.

## How The App Works Internally

### 1. Startup

When the app launches, it:

1. Finds available sound files in `sound_effects/`.
2. Loads your previously saved open sound selection from `UserDefaults`.
3. Starts a power-event monitor.
4. Creates and shows the settings window.
5. Creates a menu bar status item (`Lid`).

### 2. Sleep Handling (Lid Close Path)

When the app receives the "can sleep" power message:

1. It treats this as the best moment to play the close sound while audio hardware is still alive.
2. It starts close-sound playback.
3. It temporarily delays sleep approval using an IOPM assertion.
4. After a short delay, it calls `IOAllowPowerChange` to let sleep continue.

This design improves the chance that the close sound is actually audible before the system powers audio down.

### 3. Wake Handling (Lid Open Path)

On wake events, the app can receive signals from more than one source (IOKit and workspace notifications). To avoid duplicate sounds, it uses dedup logic.

Wake flow:

1. Deduplicate very-close wake events.
2. Attempt open-sound playback immediately.
3. Retry on delays (`0.25s`, `0.75s`, `1.5s`) in case audio hardware is not ready yet.
4. Stop retrying once one attempt succeeds.

This retry strategy improves reliability on systems where audio devices become available shortly after wake.

### 4. Sound Playback Strategy

For playback, the app prefers `AVAudioPlayer` and falls back to `NSSound` if needed.

- `AVAudioPlayer` is prepared and cached per file path for faster start.
- `NSSound` is used as a fallback path if AVAudioPlayer setup/play fails.

Close sound uses a system default path.
Open sound uses your selected file (or a fallback system sound if none is selected).

### 5. Settings Window

The settings window provides:

- Search field to filter sound names.
- Table list of available files.
- Single-selection behavior that immediately updates saved preference.
- Preview button (and double-click) to test the currently selected open sound.

Selection is persisted by filename in `UserDefaults` under key `openLidSoundFile`.

## Important Notes

- The app is designed around macOS power notifications, which usually map to lid close/open on MacBooks.
- In clamshell mode or special power/display setups, behavior may vary.
- The app keeps running after the settings window is closed (menu bar app behavior).

## Key Components (Source Overview)

- `SoundCatalog`: discovers supported audio files in `sound_effects/`.
- `SoundSelectionStore`: loads/saves selected sound in `UserDefaults`.
- `SoundPlayer`: handles open/close playback, caching, and fallback logic.
- `PowerEventMonitor`: listens for sleep/wake messages and coordinates timing.
- `SettingsWindowController`: search/select/preview UI for sound choice.
- `AppDelegate`: startup wiring, status bar menu, and app lifecycle.
