# Open Lid Sound

Open Lid Sound is a native macOS background app written in Swift.

It listens for sleep/wake power events and plays:
- a close sound when the MacBook goes to sleep (typically lid close)
- an open sound when the MacBook wakes up (typically lid open)

It also opens a settings window where you can choose the open-lid sound from files inside `sound_effects/`.

## Build

```bash
cd /Users/mac/GitHub/fahhh
swift build -c release
```

## Run manually

```bash
.build/release/OpenLidSounds
```

## Choose open-lid sound

- Put `.mp3`, `.wav`, `.m4a`, `.aiff`, `.aif`, or `.caf` files into `sound_effects/`.
- Launch `OpenLidSounds`.
- In the app window, pick an **Open-lid sound** from the dropdown.
- Use **Preview Open Sound** to test it.
- The selection is saved and reused on next startup.

## Install at login (startup)

```bash
chmod +x scripts/install-launch-agent.sh scripts/uninstall-launch-agent.sh
./scripts/install-launch-agent.sh
```

This installs a LaunchAgent at:
- `~/Library/LaunchAgents/com.openlidsounds.agent.plist`

## Uninstall

```bash
./scripts/uninstall-launch-agent.sh
```

## Notes

- The app uses system power events (`kIOMessageSystemWillSleep` and `kIOMessageSystemHasPoweredOn`).
- On MacBooks, those usually correspond to lid close/open.
- In clamshell mode or when external display settings override sleep behavior, events may differ.
