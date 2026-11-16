# MacKeyBridge

Use a MacBook's **built-in keyboard and trackpad** to control a **Windows PC** over Wi-Fi/LAN. The **Fn** key switches the Windows keyboard layout (e.g. English <-> Russian), Mac shortcuts such as `Cmd+C` become `Ctrl+C`, the trackpad becomes a real mouse (the Mac cursor is captured while you work on the PC), and a **two-finger horizontal swipe turns slides or pages**.

Two small programs, one source file each:

| Part | File | Language |
|---|---|---|
| Windows server (tray app) | [`windows/MacKeyBridge.cpp`](windows/MacKeyBridge.cpp) | C++20, Win32 API only |
| macOS client (window + menu bar item) | [`mac/main.swift`](mac/main.swift) (+ [`mac/build-app.sh`](mac/build-app.sh)) | Swift, AppKit |

```
MacBook keyboard + trackpad --> macOS client --(TCP, Wi-Fi/LAN)--> MacKeyBridge.exe --> SendInput --> any Windows app
```

> **Status:** keyboard forwarding and the Fn layout switch have been used on the author's MacBook + Windows PC. Version 2.1 of the macOS client reworked mouse capture, the emergency hotkey and trackpad swipes (the Windows server and the wire protocol are unchanged). The pure logic of the new parts is covered by `MacKeyBridge --selftest`; everything that needs real hardware and macOS permissions is covered by the [manual test checklist](#testing). It is a hobby project; issues and pull requests are welcome.

## Features

- Persistent TCP connection, a few bytes per event, auto-reconnect.
- **Mouse forwarding with real capture:** while forwarding is on, the Mac cursor is detached and hidden, clicks and scrolling no longer reach macOS, and everything goes to the PC. See [Mouse forwarding](#mouse-forwarding-how-it-works).
- **Emergency hotkey** (default `Control+Option+Command+W`, changeable) that works from any app, with three independent detection paths. See [Emergency hotkey](#emergency-hotkey).
- **Swipe navigation:** two fingers left -> right = previous slide/page, right -> left = next. See [Swipe navigation](#swipe-navigation-slides-and-pages).
- Pointer movement, tap and click (left, right, middle), drag, two-finger scroll (vertical + horizontal) with pointer speed, scroll speed and scroll-direction settings.
- **Mac client with a GUI:** connect/disconnect, status, start/stop forwarding, hotkey recorder, swipe settings, permission status with shortcuts to the right System Settings panes, log; remembers its settings.
- Keys are injected by scan code, so the active Windows layout decides the character (works in browsers, VS Code, Discord, terminals, most games).
- **Fn tap = switch layout.** Layouts cycle in the order configured in the settings (ENG -> RUS -> ENG, more can be added).
- **Mac Mode:** Left Command acts as Ctrl, Right Command acts as the Windows key, plus Mac-style shortcuts and text navigation.
- Tray icon showing the current layout (EN / RU) and connection state (grey / blue / green).
- Settings window, **Keyboard Test** window (shows physical key, Mac keycode, scan code, VK, mapped action), log file, start with Windows.
- No kernel drivers, no admin rights needed.
- No stuck keys or buttons: everything is released on the PC when forwarding stops or the connection drops, and a release that belongs to a press made before forwarding started goes to the Mac instead of being lost.

## Requirements

- Windows 10/11 and a C++20 compiler (Visual Studio 2022 with "Desktop development with C++", or MinGW-w64 / GCC 11+).
- macOS 12+ with the Xcode Command Line Tools (`xcode-select --install`).
- Both computers on the same network.

## Quick start

### 1. Windows (server)

Open the **x64 Native Tools Command Prompt for VS 2022** in the `windows` folder:

```bat
cl /std:c++20 /O2 /EHsc /utf-8 MacKeyBridge.cpp
```

MinGW-w64 alternative:

```bat
g++ -std=c++20 -O2 -static -mwindows MacKeyBridge.cpp -o MacKeyBridge.exe -lws2_32 -lbcrypt -lgdi32 -lcomctl32 -lshell32 -ladvapi32 -luser32
```

Run `MacKeyBridge.exe`. The settings window shows the **port** (47800), the **secret** and a ready-to-copy command for the Mac. A tray icon appears.

Open the port in the Windows firewall (command prompt as administrator):

```bat
netsh advfirewall firewall add rule name="MacKeyBridge" dir=in action=allow protocol=TCP localport=47800 profile=any
```

### 2. macOS (client)

Build the app bundle (recommended: it gets its own entry in the macOS privacy lists):

```bash
cd mac
chmod +x build-app.sh
./build-app.sh        # compiles main.swift, creates MacKeyBridge.app and opens it
```

Or compile and run the bare binary (the privacy permissions are then attached to the **Terminal** app you start it from):

```bash
cd mac
swiftc -O main.swift -o MacKeyBridge && ./MacKeyBridge
```

A window opens. Enter the PC's **address** (its IPv4 address in your home network, `ipconfig` on the PC, e.g. `192.168.x.x` - not a VPN address), the **port** (47800) and the **secret** from the Windows settings, then click **Connect**. The settings are remembered.

Then grant the permissions described in [Permissions](#permissions-macos). **Forwarding cannot be started until both Accessibility and Input Monitoring are granted.**

Also set **System Settings -> Keyboard -> "Press Globe key to" = Do Nothing**, so macOS does not react to Fn.

Optional command line (prefills the window and connects at once): `./MacKeyBridge --host <PC-IP> --port 47800 --secret <secret>`.

| Option | Meaning |
|---|---|
| `--host`, `--port`, `--secret` | connection settings (also `MACKEYBRIDGE_HOST`, `MACKEYBRIDGE_SECRET`) |
| `--selftest` | run the built-in logic tests (swipe recognizer, hotkey matching, stuck-key bookkeeping) and exit; needs no permissions |
| `--diagnose` | print the permission state and count the events an event tap really receives for 8 seconds, then exit (see [Troubleshooting](#troubleshooting)) |

With the bundle, run them as `./MacKeyBridge.app/Contents/MacOS/MacKeyBridge --selftest`.

### 3. Use it

1. Connect (status turns green).
2. Press the hotkey (default **`Control+Option+Command+W`**) from any app, or click **Start forwarding** in the window or menu bar item. The menu bar shows `⌨ → PC`.
3. The keyboard and trackpad now control Windows; the Mac cursor stays frozen and Mac apps get no input.
4. Press the hotkey again to get everything back on the Mac. **The hotkey is the way back** - clicking the window does not work while the trackpad is captured.

Tap **Fn** to switch the Windows layout. Trackpad: move = pointer, tap or click = left click, two-finger click/tap = right click, two-finger vertical swipe = scroll, two-finger horizontal swipe = previous/next slide. Tap-to-click must be enabled in the Mac's trackpad settings if you want taps.

## Mouse forwarding: how it works

The macOS client installs an **active session event tap** (`CGEventTap`, `.cgSessionEventTap`, head insertion, `.defaultTap`) that sees keyboard, pointer, scroll and gesture events before any app does.

**Capture** (when forwarding starts and *Forward trackpad / mouse too* is on):

1. The cursor is detached from the pointing device with `CGAssociateMouseAndMouseCursorPosition(0)`. The cursor no longer moves, but macOS keeps reporting **relative movement** (`mouseEventDeltaX/Y`) to the tap.
2. The cursor is hidden (`CGDisplayHideCursor`, balanced on release). Hiding is cosmetic - macOS may ignore it when MacKeyBridge is not the frontmost app - the detach is what actually holds the cursor.
3. Every pointer event (move, drag, left/right/other buttons, scroll, and the pinch/rotate/swipe gesture events) is **swallowed** by the tap, so macOS never processes it, and the same input is sent to the PC. Input is never delivered to both computers.
4. While captured, every move event is checked: if the cursor position changes anyway (the detach did not take effect), the detach is applied again and a line is written to the log.

What is forwarded: pointer movement (sub-pixel remainders are kept, so slow movement is not lost), left / right / middle / back / forward buttons, drag, vertical and horizontal scrolling. Media keys for volume and play/next/previous are forwarded too; brightness and backlight keys stay on the Mac.

**Release** is one idempotent function used by every exit path. It re-attaches the cursor **first**, then shows it again if it was hidden, then puts it back where it was when capture started *only if* it was moved. Then `ALL_UP` is sent to the PC, which releases every key and mouse button still held there.

Forwarding is released automatically when:

- you press the hotkey, click *Stop forwarding* or use the menu bar item;
- the connection to the PC is lost (as soon as the client notices it), or you click *Disconnect*;
- macOS switches the event tap off (timeout or user input), or the tap is found disabled by the 1-second watchdog;
- Accessibility or Input Monitoring is revoked while forwarding;
- the Mac goes to sleep, the screen sleeps, or the user session is switched away (fast user switching);
- the app quits, or receives `SIGINT` / `SIGTERM` / `SIGHUP`.

At start-up the app also re-attaches the cursor once, in case a previous instance was killed while forwarding. If *Forward trackpad / mouse too* is off, only the keyboard is forwarded and the trackpad keeps controlling the Mac.

**Stuck keys and buttons:** the client remembers which presses it actually forwarded. A key, modifier or mouse button that was already down when forwarding started (for example the `Control+Option+Command` you are still holding after pressing the hotkey) is *not* forwarded when it is released - the release is left for the Mac, so neither computer ends up with a key stuck down.

## Emergency hotkey

Default: **`Control+Option+Command+W`**. It toggles forwarding: it starts it when it is off and stops it when it is on. It works whichever app is in front, whether the MacKeyBridge window is active or not, and in any forwarding state.

Pressing it while forwarding is on does, in this order: re-attach the Mac cursor, show it again, restore its position if needed, send `ALL_UP` to the PC, reset the interface to *Start forwarding*. The Mac cursor and keyboard control macOS again immediately.

**Three independent detection paths**, so one failure cannot leave you locked in:

| Path | How | Covers |
|---|---|---|
| Emergency tap | a second, tiny event tap on its **own thread** that only looks for the hotkey and sits in front of the main tap | a busy or stalled main thread / UI |
| Main tap | the forwarding tap itself | fallback if the emergency tap could not be created |
| Carbon hotkey | `RegisterEventHotKey`, needs no privacy permission | permission revoked, tap disabled, Secure Event Input |

One key press can arrive through several paths; duplicates within 0.4 s are ignored. The hotkey itself is never forwarded to the PC.

### Changing the hotkey

In the MacKeyBridge window click **Change...** next to *Emergency hotkey*, then press the new combination (`Esc` cancels). **Reset** restores `Control+Option+Command+W`. Rules:

- at least **two** of `Control`, `Option`, `Command` must be part of it (so it cannot swallow an everyday shortcut); `Shift` is optional;
- the taps fire even if extra modifiers (e.g. Shift) are held, because in an emergency keys are not pressed carefully; the Carbon fallback needs the exact combination;
- the hotkey cannot be changed while forwarding is on.

The hotkey is stored in the app's preferences (`hotkeyCode`, `hotkeyFlags`, `hotkeyName`) and used by all three paths.

## Swipe navigation (slides and pages)

With **Two-finger horizontal swipe = previous / next slide or page** enabled (default), a horizontal two-finger swipe on the trackpad is turned into a key press on the PC instead of horizontal scrolling:

| Gesture (fingers move ...) | Sent to Windows |
|---|---|
| left -> right | previous slide / page |
| right -> left | next slide / page |

It is sent as an ordinary key press over the existing key packets (the protocol is unchanged). **Swipe sends** chooses the keys:

| Setting | Previous / next | Typically good for |
|---|---|---|
| Left / Right arrow (default) | `←` / `→` | PowerPoint and Google Slides in slide show mode, PDF viewers |
| Page Up / Page Down | `Page Up` / `Page Down` | PowerPoint's normal (editing) view and slide sorter |

How it behaves:

- **Horizontal vs vertical:** the macOS scroll *phase* events (began / changed / ended, plus momentum) are used to treat each gesture as a whole. After about 10 points of travel the axis is decided: mostly horizontal = swipe, otherwise = ordinary vertical scroll. A vertical scroll never changes slides, and a swipe never scrolls the page sideways.
- **Threshold:** the swipe fires when the finger travel reaches **Swipe distance** (slider, 30-300, default 80 scroll points) and horizontal movement is at least twice the vertical movement. Small horizontal drifts do nothing.
- **One switch per gesture:** exactly one step per gesture, fired as soon as the threshold is reached; the rest of that gesture and its inertia are ignored. A new gesture (fingers touch down again) re-arms it, with a 0.25 s minimum gap between two swipes.
- **Direction:** it follows the **finger** movement, so it does not depend on the macOS *Natural scrolling* setting. If it feels reversed on your Mac, tick **Reverse swipe direction**.
- **Mouse wheels and modifiers:** only continuous trackpad / Magic Mouse scrolling is interpreted. A normal mouse wheel, or any scrolling while `Shift`, `Control`, `Option` or `Command` is held, is forwarded as plain scrolling (including horizontal).
- It works only while forwarding is on. Untick the option to forward vertical **and** horizontal two-finger scrolling as before (needed for e.g. wide spreadsheets).

Three- and four-finger gestures (Mission Control, Spaces, App Exposé) are handled by macOS itself and cannot be forwarded or blocked. Pinch, rotate and smart-zoom events are swallowed while forwarding so they do not act on the Mac, but they are not sent to the PC either.

## Permissions (macOS)

Open **System Settings -> Privacy & Security**. The window shows the status and has an *Open settings...* button for each pane. Grant them to **MacKeyBridge.app** (or to your terminal if you run the bare binary).

| Permission | Needed for | If missing |
|---|---|---|
| **Accessibility** | the active event tap that swallows keys, clicks and scrolling | forwarding cannot start |
| **Input Monitoring** | receiving keystrokes (including the hotkey) in the event tap | forwarding cannot start. On recent macOS versions a tap can be created with Accessibility alone yet may not receive keystrokes, so MacKeyBridge requires both |
| **Local Network** | connecting to the PC on your LAN | `No route to host` / `Timed out` |

No other permissions are needed (no Screen Recording, Full Disk Access, Automation or Camera/Microphone).

Steps: click *Open settings...*, enable the switch for MacKeyBridge (use `+` to add it if it is not listed), then return to the window - the status turns green and *Start forwarding* becomes available by itself. If macOS asks to quit and reopen the app, do so.

**After rebuilding the app**, macOS may keep the old entry but no longer trust the new binary (the ad-hoc signature changes with every build). If the window says *not granted* although the switch is on, remove the entry with `-` and add the app again, or reset it:

```bash
tccutil reset Accessibility local.mackeybridge.client
tccutil reset ListenEvent local.mackeybridge.client
```

Missing permissions never leave the mouse captured: forwarding refuses to start, and if a permission is revoked while forwarding, it is released within about a second.

## Settings in the Mac window

| Setting | Meaning |
|---|---|
| Address / Port / Secret | where to connect and the shared secret from the Windows settings |
| Start / Stop forwarding | same as the hotkey (also in the menu bar item) |
| **Emergency hotkey** - Change... / Reset | record a new hotkey / restore `Control+Option+Command+W` |
| Forward trackpad / mouse too | Off = only the keyboard is forwarded, the trackpad keeps controlling the Mac (no capture) |
| Pointer speed | Multiplier for pointer movement (Windows applies its own acceleration on top; disable *Enhance pointer precision* in Windows mouse settings if the pointer feels odd) |
| Scroll speed | Multiplier for scrolling |
| Invert vertical / horizontal scroll | Flip the direction if scrolling feels backwards on Windows |
| **Two-finger horizontal swipe = previous / next** | Turns horizontal swipes into slide/page navigation (default on) |
| **Swipe distance** | Finger travel that triggers a swipe (30-300, default 80) |
| **Swipe sends** | `Left / Right arrow` or `Page Up / Page Down` |
| **Reverse swipe direction** | Swap previous / next |
| Connect automatically when the app starts | Auto-connect with the saved settings |

Settings are saved in the app's preferences (`UserDefaults`; with the bundle: `defaults read local.mackeybridge.client`). Keys: `host`, `port`, `secret`, `forwardMouse`, `pointerSpeed`, `scrollSpeed`, `invertV`, `invertH`, `autoConnect`, `swipeNav`, `swipeThreshold`, `swipeKeys`, `swipeReverse`, `hotkeyCode`, `hotkeyFlags`, `hotkeyName`.

## Key mapping (Mac Mode, default)

| Mac | Windows |
|---|---|
| Left Command | Ctrl (`Cmd+C/V/X/Z/A/S/W/T/F...` -> `Ctrl+...`) |
| Right Command | Windows key |
| Option | Alt (right Option = Right Alt / AltGr) |
| Control, Shift, Caps Lock | Ctrl, Shift, Caps Lock |
| `Cmd+Q` | `Alt+F4` |
| `Cmd+Tab` | `Alt+Tab` (switcher stays open while Command is held) |
| `Cmd+Space` | `Win+S` |
| `Cmd+M` | `Win+Down` |
| `Cmd+Ctrl+Q` | `Win+L` |
| `Cmd+Opt+Esc` | `Ctrl+Shift+Esc` |
| `Cmd+Shift+3` / `Cmd+Shift+4` | `PrintScreen` / `Win+Shift+S` |
| `Cmd+Left/Right/Up/Down` | `Home` / `End` / `Ctrl+Home` / `Ctrl+End` |
| `Option+Left/Right/Backspace` | `Ctrl+Left` / `Ctrl+Right` / `Ctrl+Backspace` |
| Volume, Play/Pause, Next/Previous | Windows media keys |

Every keyboard group can be turned off in **Settings -> Keyboard** on Windows. With Mac Mode off, Command is simply the Windows key.

### Fn

| Action | Result |
|---|---|
| Tap Fn (shorter than 0.5 s, no other key) | switch layout |
| `Fn + Arrows` | `Home` / `End` / `Page Up` / `Page Down` |
| `Fn + Backspace` | `Delete` |
| `Fn + I` | `Insert` |

The layout is switched when Fn is **released**, because that is the only way to tell "Fn" from "Fn + arrow". Turning off "Fn layer" in the settings switches immediately on press.

Fn is captured on the Mac (`CGEventTap`, key code 63) and is never sent to Windows as a normal key. Windows cannot see the Fn key of a MacBook's built-in keyboard, because that keyboard is attached to the Mac, not to the PC.

Tip: to have the top row send real `F1-F12`, enable "Use F1, F2, etc. keys as standard function keys" in the macOS keyboard settings.

### More languages

Settings are stored in `%APPDATA%\MacKeyBridge\settings.ini`:

```ini
[Languages]
languages=0x0409,0x0419        ; English (US), Russian
```

Add language IDs (for example `0x0443` Uzbek Latin, `0x0407` German) to cycle through more layouts. The layouts must be installed in Windows.

## Testing

**Automatic (no permissions needed):**

```bash
./MacKeyBridge.app/Contents/MacOS/MacKeyBridge --selftest
```

It checks the swipe recognizer (both directions, vertical scroll, small movements, one swipe per gesture, inertia, cooldown, thresholds), hotkey matching and the stuck-key bookkeeping, and prints `PASS`/`FAIL` per case.

**Manual checklist (needs the Mac, the PC and the permissions):**

1. *Start forwarding* captures the mouse: the Mac cursor stops, Mac hover effects stop.
2. Moving the trackpad moves the Windows pointer.
3. Left and right clicks (and tap-to-click) arrive on Windows; nothing is clicked on the Mac.
4. Two-finger vertical scroll scrolls the Windows window.
5. The hotkey works with another app in front, with the MacKeyBridge window closed, and with forwarding on and off.
6. The hotkey stops forwarding at once; the Mac cursor is back and the trackpad controls macOS.
7. The window and menu bar item show the right state (`Start`/`Stop forwarding`, `⌨ → PC`).
8. Swipe left -> right in a PowerPoint slide show on the PC goes to the previous slide.
9. Swipe right -> left goes to the next slide.
10. Vertical scrolling never changes slides.
11. Swipes and scrolling work while the mouse is captured (no conflict with pointer forwarding).
12. Start/stop several times in a row, then press the hotkey once: it still toggles exactly once (no duplicated handlers).
13. Disconnect the Wi-Fi while forwarding: press the hotkey (immediate), and check that forwarding also stops by itself once the client notices the lost connection.
14. Revoke Input Monitoring while forwarding: forwarding stops and the mouse is released.

## Troubleshooting

| Problem | Fix |
|---|---|
| The Mac window shows a red status (`Timed out`, `Connection refused`, `No route to host`) | The message says what failed. Check the IP/port, that MacKeyBridge is running (tray icon not grey), and test with `nc -vz <PC-IP> 47800` on the Mac. |
| `nc` says `timed out` / `No route to host` | Add the firewall rule above (or set the Windows network to Private); allow **Local Network** for MacKeyBridge (or your terminal) in macOS; make sure both devices are on the same subnet and the Wi-Fi has no client isolation. |
| IP starts with `26.` or `25.` | That is a VPN address (Radmin VPN / Hamachi). Use the `192.168.x.x` / `10.x.x.x` address of your home network. |
| `Wrong secret` | Copy the secret from the Windows settings window. |
| `Version mismatch` | Update both `MacKeyBridge.cpp` (rebuild the exe) and `main.swift`: they must be the same protocol version (2). |
| *Start forwarding* is disabled / the window says a permission is missing | Grant **both** Accessibility and Input Monitoring (see [Permissions](#permissions-macos)). It activates by itself; if not, restart the app. After a rebuild, remove and re-add the entries or use `tccutil reset` (see above). |
| The log says `Forwarding not started: ... permission missing` | Same as above: the missing permission is named in the message. |
| The Mac cursor still moves while forwarding | Look at the log for `Could not detach the Mac cursor` or `Cursor position changed while captured`. Run `--diagnose` to check the permissions, and make sure *Forward trackpad / mouse too* is ticked. Press the hotkey to stop. |
| The hotkey does nothing | Run `--diagnose` and type a few keys: if no keyboard events are counted, Input Monitoring is missing or **Secure Event Input** is on (a password field is focused, or Terminal -> *Secure Keyboard Entry*). The Carbon fallback still reacts to the exact registered combination. Also check that no other app uses the same combination, and that the window does not say *Press keys...* (hotkey recording is still active; press `Esc`). |
| The cursor looks frozen after the app was killed or crashed | Start MacKeyBridge again: it re-attaches the cursor at start-up. If that is not enough, log out and in. |
| Swipes go the wrong way | Tick **Reverse swipe direction**. |
| Swiping does not change slides | The PC window must have focus and be in the right mode (arrow keys change slides in slide show mode; in PowerPoint's editing view try *Swipe sends = Page Up / Page Down*). Check that the swipe option is ticked and *Forward trackpad / mouse too* is on, and lower **Swipe distance** if your swipe is too short to trigger. |
| A slide changes while scrolling vertically | Raise **Swipe distance**, and keep your fingers more vertical (a swipe needs horizontal movement of at least twice the vertical one). |
| Horizontal scrolling no longer works on Windows | By design, horizontal two-finger movement is now navigation. Untick *Two-finger horizontal swipe = previous / next*, or hold `Shift` while scrolling. |
| Windows pointer moves too fast/slow or scroll is backwards | Adjust *Pointer speed*, *Scroll speed* and the invert checkboxes in the Mac window. |
| Keys type on both computers | Forwarding is off. The window button should say *Stop forwarding* and the menu bar `⌨ → PC`. |
| A key or mouse button seems stuck on the PC | Stop forwarding with the hotkey: stopping sends `ALL_UP`. The server also releases everything if nothing arrives for 3 seconds. |
| Fn does nothing | Open tray -> **Keyboard Test**, enable forwarding, press Fn: you should see `Physical key: Fn`. Tap it briefly and without other keys. |
| Wrong keys next to Left Shift / top-left | Enable "ISO keyboard" in the settings. |
| Layout switch ignored in one app | Settings -> Languages -> switch method: try `Win+Space`. |

Log file on Windows: `%APPDATA%\MacKeyBridge\log.txt` (enable *Debug mode* to log every key event). The Mac window has its own log box, and the same lines go to the terminal when the app is started from there.

## Security

- Every connection is authenticated with an HMAC-SHA256 challenge-response using the shared secret (the secret is never sent over the network).
- **Key presses are not encrypted.** Anyone who can sniff your network can read what you type, including passwords. Use a trusted network, or a VPN such as Tailscale and connect through its address.
- Anyone who knows the secret and can reach the port can type on your PC. Keep the secret private and do not commit `settings.ini` to a repository.

## Limitations

- Games with anti-cheat (EAC, BattlEye, Vanguard, ...) treat `SendInput` as injected input and may block it. Do not use this in such games.
- Windows apps running as administrator ignore input from a normal process (UIPI). Run MacKeyBridge as administrator if you need that.
- The lock screen, UAC prompts and `Ctrl+Alt+Del` cannot be controlled through `SendInput`.
- macOS blocks event taps from seeing keystrokes while *Secure Input* is active (password fields in some apps, Secure Keyboard Entry in Terminal). The Carbon hotkey can still stop forwarding, but keys are not forwarded meanwhile.
- Hiding the Mac cursor is best effort (macOS may ignore it when the app is not frontmost); the cursor is frozen in either case.
- A forcibly killed process (`kill -9`) cannot clean up after itself: starting the app again re-attaches the cursor.
- Swipe navigation sends plain arrow / Page keys, so it works in whatever Windows app interprets them; it cannot know whether a presentation is open. Only two-finger horizontal gestures are interpreted; three-finger gestures stay with macOS.
- In swipe mode a vertical gesture drops its small horizontal component, and horizontal two-finger scrolling is replaced by navigation (turn the option off to get it back).
- The swipe direction relies on macOS reporting the natural-scrolling flag correctly; use *Reverse swipe direction* if it does not.
- Mac keyboards/trackpads only; media keys other than volume/play/next/previous (brightness, keyboard backlight) stay on the Mac.
- Pinch, rotate and three-or-more-finger gestures are not forwarded.
- The Mac client stores its settings, including the secret, in the app's preferences (`UserDefaults`) in plain text.

## Protocol (version 2)

Unchanged in 2.1. After the TCP connection the server sends a 16-byte challenge; the client answers with `HMAC-SHA256(secret, nonce)` and the protocol version; the server replies `AUTH_OK` or `AUTH_FAIL` + reason (1 wrong secret, 2 version mismatch). Then the client sends events; the first byte is the type and fixes the length:

```
0x10 KEY_DOWN     [type][flags][code lo][code hi]       4 bytes (flags bit 0 = auto-repeat)
0x11 KEY_UP       [type][flags][code lo][code hi]       4 bytes
0x12 ALL_UP       [type][0][0][0]                       4 bytes - release keys and mouse buttons
0x13 PING         [type][0][0][0]                       4 bytes
0x20 MOUSE_MOVE   [type][dx int16][dy int16]            5 bytes, relative pixels
0x21 MOUSE_BUTTON [type][button][down]                  3 bytes, 0 left 1 right 2 middle 3 back 4 forward
0x22 MOUSE_WHEEL  [type][dx int16][dy int16]            5 bytes, 120 = one notch, dy>0 up, dx>0 right
```

Key code: macOS virtual key code, or `0x100 + NX_KEYTYPE` for media keys (Fn = 63). Swipe navigation uses ordinary key packets: `123` / `124` (Left / Right arrow) or `116` / `121` (Page Up / Page Down), each as KEY_DOWN followed by KEY_UP. The client pings every second; the server releases all keys and mouse buttons if nothing arrives for 3 seconds.
