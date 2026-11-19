# AGENTS.md

## Repo shape
- Two standalone programs, no workspace/package manager: `Mac/` (Swift: AppKit + SwiftUI) and `Windows/MacKeyBridge.cpp` (C++20 Win32; compile only on Windows).
- `Mac/main.swift` is the executable entrypoint: `Prefs` and protocol constants at the top; bottom initializes `Link`, `Forwarder`, `ClipboardSync`, `AppController`. CLI checks exit before `NSApplication`.
- `Mac/UI.swift` owns `AppModel` and all SwiftUI views; views read model state, engine lives in `main.swift`, `Clipboard.swift`, `KeyboardMapping.swift`; metrics/logging live in `Diagnostics.swift`.
- README is good for behavior but trust `Mac/build-app.sh` and `main.swift` for exact build/protocol details; the UI section has tabs/themes/diagnostics now.

## Commands
- Build app: `cd Mac && chmod +x build-app.sh && ./build-app.sh`. Run from `Mac/`; from repo root `swiftc` fails with `error opening input file 'Clipboard.swift'`.
- The script builds all five Swift files with `-target "$(uname -m)-apple-macosx12.0"`; do not drop `-target` or any source file.
- Stable permissions across rebuilds: `SIGN_IDENTITY="MacKeyBridge Dev" ./build-app.sh` from `Mac/`. Default ad-hoc signing changes identity each build and can require re-granting Accessibility/Input Monitoring.
- Fast binary: from `Mac/`, `swiftc -O main.swift Clipboard.swift KeyboardMapping.swift Diagnostics.swift UI.swift -o MacKeyBridge && ./MacKeyBridge`.
- Logic tests: from `Mac/`, `swiftc -O main.swift Clipboard.swift KeyboardMapping.swift Diagnostics.swift UI.swift -o /tmp/mkb-selftest && /tmp/mkb-selftest --selftest`. No permissions or PC needed; covers swipe, hotkey, stuck keys, clipboard frames, keyboard mapping and diagnostics.
- Diagnostics: `./MacKeyBridge --diagnose` counts real event-tap events for 8 s. Run `open MacKeyBridge.app` to test app permissions; running the bundle binary from a terminal reports the terminal's rights.
- Windows server, from `Windows/` in VS x64 Native Tools: `cl /std:c++20 /O2 /EHsc /utf-8 MacKeyBridge.cpp`; MinGW: `g++ -std=c++20 -O2 -static -mwindows MacKeyBridge.cpp -o MacKeyBridge.exe -lws2_32 -lbcrypt -lgdi32 -lcomctl32 -lshell32 -ladvapi32 -luser32 -lole32`.
- No lint/typecheck/CI/test-runner config exists; verification is `swiftc` compile + `--selftest` + README manual checklist.
- Inspect saved settings: `defaults read local.mackeybridge.client`.

## Constraints/gotchas
- Protocol v4 packet layout is duplicated in `Mac/main.swift` and `Windows/MacKeyBridge.cpp`; integers are little-endian. Changing packet kinds/lengths requires matching edits on both sides plus selftest parser updates. The Mac offers v4 and steps down to v3 then v2 on version mismatch. Sequence-numbered heartbeat metrics and `HOST_INFO` require v4; older peers keep the original zeroed `PING` keepalive.
- Keyboard mapping is Mac-side, before the wire: single Command → wire code 54 (Windows maps to `VK_RWIN`), `Cmd+C/V/...` → `Ctrl+...`, `Cmd+Shift+Z` → `Ctrl+Y`, `Cmd+Tab` → `Alt+Tab`; `Cmd+Shift+Esc`, `Cmd+Space`, `Cmd+Q` stay on Mac. Do not add this to the Windows mapper.
- Clipboard sync needs protocol 3 on both sides, both toggles on, 20 MiB/item; password-manager/private clipboard types and files are skipped.
- `Prefs` in `main.swift` owns all `UserDefaults` keys; new settings belong there, mirrored in `AppModel` and surfaced in UI. Theme keys: `themePreset`, `appearanceMode`, `liquidGlassEnabled`, `useCustomAccent`, `customAccent`, `selectedTab`. Diagnostics keys: `diagnosticsEnabled`, `heartbeatInterval`, `highLatencyThreshold`, `packetLossWarning`, `diagnosticLogging`, `graphHistoryDuration`.
- `liquidGlassEnabled` defaults to true; full-window transparency uses `NSVisualEffectView(blendingMode: .behindWindow)` only when enabled; `.glassEffect` is macOS 26+ with material fallback. Keep glass selective on navigation/panels/controls; do not make all text transparent.
- CLI: `--host`/`--port`/`--secret` or `MACKEYBRIDGE_HOST`/`MACKEYBRIDGE_SECRET`; unknown args are ignored. Auto-connect needs host+secret and either both CLI overrides or saved `autoConnect`.
- `Mac/MacKeyBridge.app/` and root `*.zip` archives are build outputs, not ignored by `.gitignore`; do not commit them unless explicitly asked.
- Windows C++ cannot be compiled in this macOS environment; change `Windows/MacKeyBridge.cpp` only for deliberate Windows-side work.
