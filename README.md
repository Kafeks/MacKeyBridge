# MacKeyBridge

Use a MacBook's **built-in keyboard and trackpad** to control a **Windows PC** over Wi-Fi/LAN. The **Fn** key switches the Windows keyboard layout (e.g. English <-> Russian), and Mac shortcuts such as `Cmd+C` become `Ctrl+C`.

Two small programs, one file each:

| Part | File | Language |
|---|---|---|
| Windows server (tray app) | [`windows/MacKeyBridge.cpp`](windows/MacKeyBridge.cpp) | C++20, Win32 API only |
| macOS client (window + menu bar item) | [`mac/main.swift`](mac/main.swift) (+ optional [`mac/build-app.sh`](mac/build-app.sh)) | Swift, AppKit |

```
MacBook keyboard --> macOS client --(TCP, Wi-Fi/LAN)--> MacKeyBridge.exe --> SendInput --> any Windows app
```

> **Status:** keyboard forwarding and the Fn layout switch work on the author's MacBook + Windows PC. Trackpad forwarding and the Mac window (protocol 2) are new and may need tuning (pointer/scroll speed and direction). It is a hobby project and not widely tested; issues and pull requests are welcome.

## Features

- Persistent TCP connection, a few bytes per event, auto-reconnect.
- **Trackpad / mouse:** pointer movement, tap and click (left, right, middle), drag, two-finger scroll (vertical + horizontal), with pointer speed, scroll speed and scroll-direction settings.
- **Mac client with a GUI:** connect/disconnect, status, start/stop forwarding, sliders and checkboxes for the trackpad, permission status with shortcuts to the right System Settings panes, log, remembers its settings.
- Keys are injected by scan code, so the active Windows layout decides the character (works in browsers, VS Code, Discord, terminals, most games).
- **Fn tap = switch layout.** Layouts cycle in the order configured in the settings (ENG -> RUS -> ENG, more can be added).
- **Mac Mode:** Left Command acts as Ctrl, Right Command acts as the Windows key, plus Mac-style shortcuts and text navigation.
- Tray icon showing the current layout (EN / RU) and connection state (grey / blue / green).
- Settings window, **Keyboard Test** window (shows physical key, Mac keycode, scan code, VK, mapped action), log file, start with Windows.
- No kernel drivers, no admin rights needed.
- Release-all on disconnect: no stuck keys.

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

```bash
cd mac
swiftc -O main.swift -o MacKeyBridge && ./MacKeyBridge
```

A window opens. Enter the PC's **address** (its IPv4 address in your home network, `ipconfig` on the PC, e.g. `192.168.x.x` - not a VPN address), the **port** (47800) and the **secret** from the Windows settings, then click **Connect**. The settings are remembered.

Run from the Terminal like this, macOS attaches the privacy permissions to the Terminal app. For a standalone app with its own permissions build the bundle instead:

```bash
cd mac
chmod +x build-app.sh
./build-app.sh        # creates and opens MacKeyBridge.app
```

Permissions (the window shows their status and has buttons that open the right panes of **System Settings -> Privacy & Security**): **Accessibility**, **Input Monitoring** and **Local Network**. Grant them to the app (or to your terminal when you use the quick command). After rebuilding the app macOS may ask again.

Also set **System Settings -> Keyboard -> "Press Globe key to" = Do Nothing**, so macOS does not react to Fn.

Optional command line (prefills the window and connects at once): `./MacKeyBridge --host <PC-IP> --port 47800 --secret <secret>`.

### 3. Use it

- `Control + Option + Command + W` (or the button in the window / the menu bar item) toggles forwarding: the keyboard **and trackpad** control Windows (`⌨ → PC`) or are back on the Mac.
- While forwarding is on, the Mac cursor stays still and clicks do nothing on the Mac. **The hotkey is the way back**, it always works.
- Tap **Fn** to switch the Windows layout.
- Trackpad: move = pointer, tap or click = left click, two-finger click/tap = right click, two-finger swipe = scroll. Tap-to-click must be enabled in the Mac's trackpad settings if you want taps.

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

## Trackpad settings (in the Mac window)

| Setting | Meaning |
|---|---|
| Forward trackpad / mouse too | Off = only the keyboard is forwarded, the trackpad keeps controlling the Mac |
| Pointer speed | Multiplier for pointer movement (Windows applies its own acceleration on top; disable *Enhance pointer precision* in Windows mouse settings if the pointer feels odd) |
| Scroll speed | Multiplier for scrolling |
| Invert vertical / horizontal scroll | Flip the direction if scrolling feels backwards on Windows |

Swipes with three or four fingers (Mission Control, desktops) are handled by macOS itself and are not forwarded.

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

## Troubleshooting

| Problem | Fix |
|---|---|
| The Mac window shows a red status (`Timed out`, `Connection refused`, `No route to host`) | The message says what failed. Check the IP/port, that MacKeyBridge is running (tray icon not grey), and test with `nc -vz <PC-IP> 47800` on the Mac. |
| `nc` says `timed out` / `No route to host` | Add the firewall rule above (or set the Windows network to Private); allow **Local Network** for your terminal in macOS; make sure both devices are on the same subnet and the Wi-Fi has no client isolation. |
| IP starts with `26.` or `25.` | That is a VPN address (Radmin VPN / Hamachi). Use the `192.168.x.x` / `10.x.x.x` address of your home network. |
| `Wrong secret` | Copy the secret from the Windows settings window. |
| `Version mismatch` | Update both `MacKeyBridge.cpp` (rebuild the exe) and `main.swift`: they must be the same version (protocol 2). |
| Window says permissions are missing / forwarding button is disabled | Grant Accessibility and Input Monitoring (the window has buttons for it). It activates by itself; if not, restart the app. |
| Windows pointer moves too fast/slow or scroll is backwards | Adjust *Pointer speed*, *Scroll speed* and the invert checkboxes in the Mac window. |
| Mac cursor stays frozen after a crash | Press `Control+Option+Command+W`, or quit and reopen MacKeyBridge. |
| Keys type on both computers | Forwarding is off. The window button should say *Stop forwarding* and the menu bar `⌨ → PC`. |
| Fn does nothing | Open tray -> **Keyboard Test**, enable forwarding, press Fn: you should see `Physical key: Fn`. Tap it briefly and without other keys. |
| Wrong keys next to Left Shift / top-left | Enable "ISO keyboard" in the settings. |
| Layout switch ignored in one app | Settings -> Languages -> switch method: try `Win+Space`. |

Log file: `%APPDATA%\MacKeyBridge\log.txt` (enable *Debug mode* to log every key event).

## Security

- Every connection is authenticated with an HMAC-SHA256 challenge-response using the shared secret (the secret is never sent over the network).
- **Key presses are not encrypted.** Anyone who can sniff your network can read what you type, including passwords. Use a trusted network, or a VPN such as Tailscale and connect through its address.
- Anyone who knows the secret and can reach the port can type on your PC. Keep the secret private and do not commit `settings.ini` to a repository.

## Limitations

- Games with anti-cheat (EAC, BattlEye, Vanguard, ...) treat `SendInput` as injected input and may block it. Do not use this in such games.
- Windows apps running as administrator ignore input from a normal process (UIPI). Run MacKeyBridge as administrator if you need that.
- The lock screen, UAC prompts and `Ctrl+Alt+Del` cannot be controlled through `SendInput`.
- macOS blocks event taps while *Secure Input* is active (password fields in some apps).
- Mac keyboards/trackpads only; media keys other than volume/play/next/previous (brightness, keyboard backlight) stay on the Mac.
- Trackpad gestures with three or more fingers and pinch/rotate are not forwarded.
- The Mac client stores its settings, including the secret, in the app's preferences (`UserDefaults`) in plain text.

## Protocol (version 2)

After the TCP connection the server sends a 16-byte challenge; the client answers with `HMAC-SHA256(secret, nonce)` and the protocol version; the server replies `AUTH_OK` or `AUTH_FAIL` + reason (1 wrong secret, 2 version mismatch). Then the client sends events; the first byte is the type and fixes the length:

```
0x10 KEY_DOWN     [type][flags][code lo][code hi]       4 bytes (flags bit 0 = auto-repeat)
0x11 KEY_UP       [type][flags][code lo][code hi]       4 bytes
0x12 ALL_UP       [type][0][0][0]                       4 bytes - release keys and mouse buttons
0x13 PING         [type][0][0][0]                       4 bytes
0x20 MOUSE_MOVE   [type][dx int16][dy int16]            5 bytes, relative pixels
0x21 MOUSE_BUTTON [type][button][down]                  3 bytes, 0 left 1 right 2 middle 3 back 4 forward
0x22 MOUSE_WHEEL  [type][dx int16][dy int16]            5 bytes, 120 = one notch, dy>0 up, dx>0 right
```

Key code: macOS virtual key code, or `0x100 + NX_KEYTYPE` for media keys (Fn = 63). The client pings every second; the server releases all keys and mouse buttons if nothing arrives for 3 seconds.
