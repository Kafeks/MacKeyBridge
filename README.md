# MacKeyBridge

Use a MacBook's **built-in keyboard** to type on a **Windows PC** over Wi-Fi/LAN. The **Fn** key switches the Windows keyboard layout (e.g. English <-> Russian), and Mac shortcuts such as `Cmd+C` become `Ctrl+C`.

Two small programs, one file each:

| Part | File | Language |
|---|---|---|
| Windows server (tray app) | [`windows/MacKeyBridge.cpp`](windows/MacKeyBridge.cpp) | C++20, Win32 API only |
| macOS client | [`mac/main.swift`](mac/main.swift) | Swift |

```
MacBook keyboard --> macOS client --(TCP, Wi-Fi/LAN)--> MacKeyBridge.exe --> SendInput --> any Windows app
```

> **Status:** works on the author's MacBook + Windows PC. It is a hobby project and not widely tested; issues and pull requests are welcome.

## Features

- Persistent TCP connection, 4 bytes per key event, auto-reconnect.
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
swiftc -O main.swift -o mackeybridge-client
./mackeybridge-client --host <PC-IP> --port 47800 --secret <secret from the Windows settings>
```

`<PC-IP>` is the PC's address in your **home network** (`ipconfig` -> IPv4 address, e.g. `192.168.x.x`). Do not use a VPN address.

Grant permissions in **System Settings -> Privacy & Security** to your terminal app: **Accessibility**, **Input Monitoring** and **Local Network**; then restart the client.

Also set **System Settings -> Keyboard -> "Press Globe key to" = Do Nothing**, so macOS does not react to Fn.

### 3. Use it

- `Control + Option + Command + W` (or the menu bar item) toggles forwarding: the keyboard types on Windows (`⌨ → PC`) or back on the Mac.
- Tap **Fn** to switch the Windows layout.

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

Every group can be turned off in **Settings -> Keyboard**. With Mac Mode off, Command is simply the Windows key.

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
| Client prints `Waiting for Windows server` | Check the IP/port, that MacKeyBridge is running (tray icon not grey), and test with `nc -vz <PC-IP> 47800` on the Mac. |
| `nc` says `timed out` / `No route to host` | Add the firewall rule above (or set the Windows network to Private); allow **Local Network** for your terminal in macOS; make sure both devices are on the same subnet and the Wi-Fi has no client isolation. |
| IP starts with `26.` or `25.` | That is a VPN address (Radmin VPN / Hamachi). Use the `192.168.x.x` / `10.x.x.x` address of your home network. |
| `Authentication failed` | Wrong secret. Copy the command from the Windows settings window. |
| `Cannot create the keyboard event tap` | Grant Accessibility and Input Monitoring to the terminal and restart the client. |
| Keys type on both computers | Forwarding is off. The menu bar should show `⌨ → PC`. |
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
- Mac keyboards only; media keys other than volume/play/next/previous stay on the Mac.

## Protocol (version 1)

After the TCP connection the server sends a 16-byte challenge; the client answers with `HMAC-SHA256(secret, nonce)` and the protocol version. Then the client sends fixed 4-byte events:

```
[type][flags][code lo][code hi]
type : 0x10 KEY_DOWN, 0x11 KEY_UP, 0x12 ALL_UP, 0x13 PING
flags: bit 0 = auto-repeat
code : macOS virtual key code, or 0x100 + NX_KEYTYPE for media keys (Fn = 63)
```

The client sends a ping every second; the server releases all keys if nothing arrives for 3 seconds.
