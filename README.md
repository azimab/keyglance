# KeyGlance (v0.1 prototype)

A menu bar app that shows the frontmost app's shortcuts. Hold any modifier (⌘ ⌥ ⌃ ⇧) and an overlay appears.
Add more modifiers to narrow it down. Release to dismiss.

- **Hold to Show** (menu bar): choose which modifiers open the overlay when held, or turn them all off.
- **Pinned Shortcut** (menu bar): record a dedicated key combo that opens the overlay already pinned. Press it again (or esc) to close. Off by default.

> "KeyGlance" is a working name.

## Shortcut Manager (menu bar)

The menu bar has a cross-app section:

- **Shortcut Manager…** opens a window with four sections:
  - **All Shortcuts**: every menu shortcut from every app KeyGlance has scanned, plus macOS system shortcuts and KeyGlance's own hotkeys. Search it, filter it by source, or show only conflicts. Right-click an app's item to change its shortcut.
  - **Conflicts**: three kinds.
    - *Blocked app shortcuts*: a macOS or KeyGlance global shortcut takes the combo first, so the app's menu item never fires.
    - *Clashing global shortcuts*: two global shortcuts share a combo.
    - *Duplicates inside an app*: one app uses the same combo for two menu items.
  - **Universal Hotkeys**: your own system-wide hotkeys that open an app, open a URL, run a shell command or show the cheat sheet.
  - **Menu Remaps**: custom menu shortcuts for one app or for every app.
- **Conflicts (N)**: a quick list of conflicts and a **Scan Running Apps** button.
- **Universal Hotkeys**: run your hotkeys from the menu, add new ones, or open the Menu Remaps section.

Each app's menus are saved in `~/Library/Application Support/KeyGlance/menus.json` whenever KeyGlance reads them, either when you switch to the app or during a scan. Apps that aren't running still count toward conflicts, using their last scan.

## Two views (switch in the overlay header or the menu bar)

| Keyboard | List |
|---|---|
| Every key is labelled with what it does **with exactly the modifiers you're holding**. Hover a key to see its full menu path in the footer. Shortcuts on keys not on the layout (⌦, Home, Page Up…) appear under "Other keys". | Every shortcut that uses **at least** the held modifiers, grouped by menu. Fuzzy search over title and menu path. |

Both views:
- Hide universal shortcuts (⌘C, ⌘V, ⌘Q…) by default; the footer shows how many are hidden.
- Hide greyed-out (disabled) menu items by default.
- Click **📌** (or click into search) to keep the overlay open after releasing the modifiers. Press **esc** or click outside to close.
- Click a modifier chip, or a modifier key on the keyboard, to change the filter.
- Use the current keyboard layout for key labels and for placing shortcuts, so AZERTY, QWERTZ, Dvorak and others work.

## Build & run

Needs only the Command Line Tools; Xcode isn't required.

```sh
./scripts/make-signing-cert.sh  # once: stable signing identity (see below)
./scripts/run.sh                # build, quit the old copy, launch the new one
```

`./scripts/build-app.sh` only builds `build/KeyGlance.app`.

On first launch, grant **Accessibility** in System Settings › Privacy & Security. The app notices the grant automatically.

**Keeping the grant across rebuilds.** macOS ties the Accessibility grant to the code signature. Ad-hoc signing changes that signature on every build, so each build would need the grant again. `make-signing-cert.sh` creates a self-signed "KeyGlance Dev" identity in your login keychain once, and the build script uses it automatically. Grant access one more time after the first signed build. If you're still on ad-hoc signing and lose the grant, run `tccutil reset Accessibility dev.keyglance.KeyGlance`, relaunch and grant again.

### Tests and previews (no permissions needed)

```sh
build/KeyGlance.app/Contents/MacOS/KeyGlance --selftest              # layout, key resolution, filtering, fuzzy search, conflicts, remap encoding
build/KeyGlance.app/Contents/MacOS/KeyGlance --snapshot build/snapshots  # PNGs of the overlay and Shortcut Manager, light + dark
```

`Package.swift` is for opening the project in Xcode. The build script calls `swiftc` directly, so it works with only the Command Line Tools installed.

### Debug: dump an app's shortcuts

```sh
build/KeyGlance.app/Contents/MacOS/KeyGlance --dump Safari
```

This prints every parsed shortcut, flagged with disabled, universal or no-key. It runs with your terminal's Accessibility permission.

## How it works

| Task | Implementation |
|---|---|
| Read shortcuts | `MenuReader.swift` walks the AX menu bar and reads `AXMenuItemCmdChar`, `…Modifiers`, `…Glyph` and `…VirtualKey` in a single `AXUIElementCopyMultipleAttributeValues` call per item. It runs on a background queue. |
| Hold detection | `HotkeyMonitor.swift` + `AppDelegate.handleFlags` use global `flagsChanged` monitors. The overlay appears after any enabled modifier is held for 0.8s (both configurable). It's cancelled if any key or mouse button is pressed, so ⌘C stays ⌘C. |
| Pinned shortcut | `GlobalHotkey.swift` registers the combo with Carbon `RegisterEventHotKey`, so it works without Accessibility and the keystroke never reaches the frontmost app. |
| Overlay | `OverlayController.swift` uses a borderless `.nonactivatingPanel` NSPanel at status-bar level, so the frontmost app keeps focus. |
| Instant display | Menus are prefetched when an app becomes active and cached per PID. The cache is refreshed whenever the overlay opens. |
| System shortcuts | `SystemHotkeys.swift` reads `com.apple.symbolichotkeys`. That file stores only the shortcuts you've changed, so a built-in table supplies the defaults and names. The IDs aren't documented, so the table is best-effort, and unknown IDs show as "System shortcut #N". |
| Universal hotkeys | `HotkeyCenter` (in `GlobalHotkey.swift`) registers any number of Carbon hotkeys. The hotkeys are saved in UserDefaults (`customHotkeys`). |
| Menu remaps | `MenuRemapper.swift` writes `NSUserKeyEquivalents` to the app's preferences, or to the global preferences for all apps. This is the same setting as System Settings › Keyboard › App Shortcuts. Menu paths are written as `"\u001bFile\u001bExport…"`. Values use `^ ~ $ @` for ⌃ ⌥ ⇧ ⌘. |
| Non-US layouts | `KeyboardLayout.swift` uses `UCKeyTranslate` on the current input source for labels and the char→key map. Characters such as `?` add an implied ⇧. |

## Known limits

- Electron and web apps often don't expose full menus. The footer warns when fewer than 8 shortcuts are found.
- Only menu-bar shortcuts are covered. Shortcuts handled in-view (e.g. a text editor's own keymap) are invisible to the Accessibility API.
- The keyboard drawing is ANSI-shaped. ISO/JIS keys still resolve, but they appear under "Other keys".
- Accessibility permission means this can't ship in the Mac App Store sandbox. Distribute it as a notarized download or a Homebrew cask.

- **Other apps' global hotkeys can't be listed.** macOS has no API for hotkeys that apps like Raycast or Rectangle register, or for event-tap tools like Karabiner. Conflicts only cover macOS system shortcuts, KeyGlance's own hotkeys and app menus. If a universal hotkey's combo is already taken, macOS refuses to register it, and the hotkey is flagged in the list.
- **Menu remaps apply only after the app relaunches.** Only AppKit apps honor them. Sandboxed apps may not read them, because their settings live in their container. In that case, use "Change Shortcut in All Apps".
- **System shortcuts are read-only.** Changing them would need an undocumented tool to apply the change, so KeyGlance opens System Settings instead.

## Next (v0.2: Detect)

Read `com.apple.symbolichotkeys` and the AeroSpace, skhd and Karabiner configs. Then show conflicts as red keys on this same keyboard view, which is why the keyboard view keys on physical key codes.
