# Dock Everywhere (MacOS-DockMirroring)

A small macOS menu-bar app that mirrors the Dock onto every display that is not currently showing it.
The copy behaves like the real Dock: same items in the same order, notification badges, running
indicators, minimized windows, folder stacks (fan/grid/list), drag and drop, and identical
right-click menus. When the real Dock moves to another display, the copies follow automatically.

## How it works

- The real Dock's items are read through the Accessibility API, so order, badges, progress bars and
  minimized windows match exactly.
- Clicking an icon in a copy presses the same item in the real Dock, so the behaviour is the same
  (launch, activate, reopen, restore minimized windows, Option/Command-click).
- Right-click menus are read from the real Dock (including app-specific items such as "New Window"
  and the Options submenu) and the chosen item is performed in the real Dock.
- Size, magnification, auto-hide, position (bottom/left/right) and the other Dock settings are read
  from `com.apple.dock`, and the geometry and Liquid Glass styling were measured against the real Dock
  on macOS 26/27.

## Battery

- With only one display connected, while the displays are asleep, or while the screen is locked,
  the app does nothing at all: no windows, no timers, no polling. It wakes up again when a display
  is connected or the session becomes active.
- With several displays, app launches/quits, Space changes and full-screen apps are handled from
  system notifications. Two light checks remain (which display has the Dock every 0.5 s, the Dock's
  contents every 2 s); both run at half the rate on battery or in Low Power Mode.
- Animations only run at full frame rate while something actually moves.

## Build and run

```bash
./scripts/build.sh
open build/MacDockEverywhere.app
```

Requires Xcode / the Swift toolchain. The app lives in the menu bar and has no Dock icon of its own.
The Liquid Glass look needs macOS 26 or later; older systems get a plain blur.

## Permissions

System Settings → Privacy & Security:

- **Accessibility** (needed for an exact copy): reads the real Dock and presses items in it.
  Without it, the copy is built from the Dock preferences and running apps (no badges or minimized windows).
- **Screen & System Audio Recording** (optional, off by default): enable it from the menu-bar icon
  ("Bruk skjermopptak"). It lets the glass turn dark/light with the background like the real Dock,
  and shows real thumbnails of minimized windows. Without it the glass follows the system appearance,
  or you can pick light/dark manually under "Glass".

macOS ties these permissions to the app's code signature. The build script supports three modes:

```bash
./scripts/build.sh                                   # ad hoc (default): safest, but macOS asks again after every rebuild
SIGN_IDENTITY="Apple Development: …" ./scripts/build.sh   # your own certificate: permissions survive rebuilds
KEEP_PERMISSIONS=1 ./scripts/build.sh                # ad hoc with a fixed identifier: permissions survive rebuilds,
                                                     # but any program signed with the same identifier inherits them
```

## Limitations

- Windows maximized on the other displays extend underneath the copy (only the real Dock can reserve
  screen space). Turning on "Automatically hide and show the Dock" makes the copies hide too.
- Because the right-click menu is read from the real Dock, the real menu flashes briefly on the
  display that shows the Dock.
- Rearranging icons by dragging is done in the real Dock; the copies update automatically.
- While a folder stack is open, the app listens for the Escape key system-wide (only to close the
  stack); the listener is removed as soon as the stack closes.

## Debugging

- `open -n build/MacDockEverywhere.app --args --dump-state /tmp/state.txt` writes the permission status and minimized-window lookup.
- `open -n build/MacDockEverywhere.app --args --dump-ax /tmp/dock.txt` writes the Dock's accessibility tree.
- `open build/MacDockEverywhere.app --args -minimumDisplays 3` simulates the single-display idle mode.
- Errors are logged to `~/Library/Logs/DockEverywhere.log`.
