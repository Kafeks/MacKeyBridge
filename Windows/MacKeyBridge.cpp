#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef WINVER
#define WINVER 0x0A00
#endif
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#ifdef _MSC_VER
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(linker, "/SUBSYSTEM:WINDOWS")
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <commctrl.h>
#include <shellapi.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// ==========================================================================
// Util.h
// ==========================================================================
inline std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

inline std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}


// ==========================================================================
// Log.h
// ==========================================================================
// Tiny thread-safe file logger: %APPDATA%\MacKeyBridge\log.txt (rotated at 1 MB).
namespace Log {
enum class Level { Debug, Info, Warn, Error };

void init(const std::wstring& dir);
void setDebug(bool on);
bool debugEnabled();

void write(Level lvl, const char* fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 2, 3)))
#endif
    ;
}  // namespace Log

#define LOG_DEBUG(...)                                              \
    do {                                                            \
        if (Log::debugEnabled()) Log::write(Log::Level::Debug, __VA_ARGS__); \
    } while (0)
#define LOG_INFO(...)  Log::write(Log::Level::Info, __VA_ARGS__)
#define LOG_WARN(...)  Log::write(Log::Level::Warn, __VA_ARGS__)
#define LOG_ERROR(...) Log::write(Log::Level::Error, __VA_ARGS__)


// ==========================================================================
// Protocol.h
// ==========================================================================
// Wire protocol between the macOS client and the Windows server (version 2).
// Mirrored by constants at the top of the macOS client (main.swift).
//
// Handshake (once per TCP connection):
//   server -> client : [0x01 CHALLENGE][16 random bytes]
//   client -> server : [0x02 AUTH][version][32 bytes HMAC-SHA256(secret, nonce)]
//   server -> client : [0x03 AUTH_OK]   or   [0x04 AUTH_FAIL][reason]  (then close)
//                      reason: 1 = wrong secret, 2 = protocol version mismatch
//
// Events (client -> server). The first byte is the type and determines the length:
//   0x10 KEY_DOWN     [type][flags][code lo][code hi]            4 bytes (flags bit0 = auto-repeat)
//   0x11 KEY_UP       [type][flags][code lo][code hi]            4 bytes
//   0x12 ALL_UP       [type][0][0][0]                            4 bytes: release keys AND mouse buttons
//   0x13 PING         [type][0][0][0]                            4 bytes
//   0x20 MOUSE_MOVE   [type][dx lo][dx hi][dy lo][dy hi]         5 bytes, int16 LE, relative, pixels
//   0x21 MOUSE_BUTTON [type][button][down 0/1]                   3 bytes, button: 0 left, 1 right, 2 middle,
//                                                                          3 back (X1), 4 forward (X2)
//   0x22 MOUSE_WHEEL  [type][dx lo][dx hi][dy lo][dy hi]         5 bytes, int16 LE, 120 = one notch,
//                                                                          dy > 0 = up, dx > 0 = right
// key code: macOS virtual key code (0..0xFF), or 0x100 + NX_KEYTYPE_* for media keys. Fn is code 63.

namespace proto {
constexpr uint8_t  kVersion     = 2;
constexpr uint16_t kDefaultPort = 47800;
constexpr size_t   kNonceLen    = 16;
constexpr size_t   kMacLen      = 32;

constexpr uint8_t kChallenge = 0x01;
constexpr uint8_t kAuth      = 0x02;
constexpr uint8_t kAuthOk    = 0x03;
constexpr uint8_t kAuthFail  = 0x04;

constexpr uint8_t kKeyDown = 0x10;
constexpr uint8_t kKeyUp   = 0x11;
constexpr uint8_t kAllUp   = 0x12;
constexpr uint8_t kPing    = 0x13;

constexpr uint8_t kMouseMove   = 0x20;
constexpr uint8_t kMouseButton = 0x21;
constexpr uint8_t kMouseWheel  = 0x22;

constexpr uint8_t kFlagRepeat   = 0x01;
constexpr size_t  kMaxEventSize = 5;

// Total length in bytes (including the type byte) of an event, or 0 for an unknown type.
inline size_t eventLength(uint8_t type) {
    switch (type) {
        case kKeyDown:
        case kKeyUp:
        case kAllUp:
        case kPing:        return 4;
        case kMouseMove:
        case kMouseWheel:  return 5;
        case kMouseButton: return 3;
        default:           return 0;
    }
}
}  // namespace proto


// ==========================================================================
// Settings.h
// ==========================================================================
enum class SwitchMethod : int {
    Api = 0,        // WM_INPUTLANGCHANGEREQUEST to the foreground window (explicit target layout)
    WinSpace = 1,   // inject Win+Space (Windows cycles its own layout list)
    AltShift = 2,   // inject Alt+Shift
    CtrlShift = 3,  // inject Ctrl+Shift
};

struct Config {
    // --- Keyboard ---
    bool macMode = true;            // master switch for the Mac-style translation layer
    bool commandShortcuts = true;   // Left Command acts as Ctrl (Cmd+C -> Ctrl+C ...)
    bool rightCmdIsWin = true;      // Right Command = Windows key (so Win+E, Win+R ... stay reachable)
    bool macTextNav = true;         // Cmd+arrows = Home/End, Option+arrows = word jump
    bool optionAsAlt = true;        // Option -> Alt (off: Option -> Windows key)
    bool isoKeyboard = false;       // swap the two keys that ISO MacBooks report differently
    bool fnLanguageSwitch = true;   // Fn toggles the Windows layout
    bool fnLayer = true;            // Fn+arrows/Backspace/I = Home/End/PgUp/PgDn/Delete/Insert; language switches on Fn *tap*
    int fnTapMs = 500;              // longest Fn press that still counts as a tap

    // --- Languages (cycled in order; add more LANGIDs later: 0x0443 Uzbek (Latin), 0x0407 German ...) ---
    std::vector<uint16_t> languages{0x0409, 0x0419};
    SwitchMethod method = SwitchMethod::Api;

    // --- Connection ---
    bool enabled = true;
    std::string bindAddress = "0.0.0.0";
    int port = 47800;
    std::string secret;

    // --- Startup / misc ---
    bool minimizeToTray = true;
    bool debug = false;
};

class Settings {
public:
    static Settings& instance();

    // Returns false if no settings file existed yet (first run).
    bool load();
    void set(Config c);  // sanitize, store, save to disk, fire onChanged
    std::shared_ptr<const Config> get() const;
    std::wstring dataDir() const { return dir_; }

    std::function<void()> onChanged;

private:
    Settings();
    void save(const Config& c) const;

    mutable std::mutex mu_;
    std::shared_ptr<const Config> cfg_;
    std::wstring dir_, path_;
};


// ==========================================================================
// KeyMapper.h
// ==========================================================================
// A physical Windows key. Injected by hardware scan code when `scan` != 0
// (this is what games / DirectInput / RawInput expect and lets the active layout
// decide the character), otherwise by virtual key.
struct WinKey {
    uint8_t vk = 0;
    uint16_t scan = 0;
    bool ext = false;  // E0-prefixed key
    bool valid() const { return vk != 0; }
    bool operator==(const WinKey& o) const { return vk == o.vk && scan == o.scan && ext == o.ext; }
};

// Modifier bits used by chords.
constexpr uint8_t kModCtrl = 1, kModAlt = 2, kModShift = 4, kModWin = 8;

// macOS virtual key codes (kVK_*) we need by name.
namespace mac {
constexpr uint16_t IsoSection = 10, Grave = 50;
constexpr uint16_t K3 = 20, K4 = 21, KI = 34, KM = 46, KQ = 12;
constexpr uint16_t Return = 36, Tab = 48, Space = 49, Backspace = 51, Escape = 53;
constexpr uint16_t RCmd = 54, LCmd = 55, LShift = 56, Caps = 57, LOpt = 58, LCtrl = 59, RShift = 60, ROpt = 61,
                   RCtrl = 62, Fn = 63;
constexpr uint16_t Left = 123, Right = 124, Down = 125, Up = 126;
constexpr uint16_t MediaBase = 0x100;  // + NX_KEYTYPE_* (volume, play/pause, ...)
}  // namespace mac

class KeyMapper {
public:
    // Plain positional mapping Mac key -> Windows key (no Mac-mode logic). Invalid WinKey if unmapped.
    static WinKey base(uint16_t macCode, bool isoKeyboard);
    // Media key (macCode >= mac::MediaBase) -> Windows media VK.
    static WinKey media(uint16_t macCode);
    // Look up a Windows key by VK (ext disambiguates Enter/KP Enter, nav cluster vs numpad).
    static WinKey byVk(uint8_t vk, bool ext = false);

    static bool isModifier(uint16_t macCode);  // Cmd, Option, Control, Shift (not Caps Lock / Fn)

    static std::string macName(uint16_t macCode);
    static std::string winName(const WinKey& k);
};


// ==========================================================================
// Injector.h
// ==========================================================================
// Thin SendInput wrapper. Keys are reference counted so several Mac keys can map to the
// same Windows key (e.g. both Command keys -> Ctrl) without sending a premature key-up.
// Not thread-safe: KeyboardManager serialises access.
class Injector {
public:
    void setDryRun(bool on) { dry_ = on; }

    void press(const WinKey& k);    // ref-counted key down
    void release(const WinKey& k);  // ref-counted key up
    void repeat(const WinKey& k);   // extra key-down (auto-repeat) without touching the count
    void tap(const WinKey& k);      // raw down+up in one batch

    // Atomically: lift all held modifiers, press `mods` (+ optional key tap), restore the modifiers.
    void chord(uint8_t mods, const WinKey* key);

    // Mouse / trackpad (relative movement, buttons 0..4 = left,right,middle,back,forward, wheel in 1/120 notch).
    void mouseMove(int dx, int dy);
    void mouseButton(int button, bool down);
    void mouseWheel(int dx, int dy);

    // Release everything we are holding (disconnect / panic): keys and mouse buttons. Masks the Win key
    // so the Start menu does not pop up.
    void releaseAll();

private:
    struct Held {
        WinKey key;
        int count = 0;
    };
    static uint32_t id(const WinKey& k) { return (uint32_t(k.vk) << 8) | (k.ext ? 1u : 0u); }
    static INPUT make(const WinKey& k, bool down);
    static INPUT maskKey(bool down);
    static INPUT makeMouse(DWORD flags, LONG dx, LONG dy, DWORD data);
    static bool buttonInput(int button, bool down, INPUT& out);
    static bool isModifierVk(uint8_t vk);
    static bool isWinVk(uint8_t vk) { return vk == VK_LWIN || vk == VK_RWIN; }
    void send(std::vector<INPUT>& v);

    std::map<uint32_t, Held> held_;
    bool mouseDown_[5] = {false, false, false, false, false};
    bool dry_ = false;
};


// ==========================================================================
// MacShortcuts.h
// ==========================================================================
// What the Mac modifiers look like at the moment a key goes down.
struct ShortcutContext {
    bool cmd = false;    // a Command key that acts as Ctrl is held
    bool opt = false;    // Option held (and Option -> Alt is enabled)
    bool ctrl = false;   // physical Control held
    bool shift = false;
    bool nav = false;    // Mac text-navigation rules enabled
};

struct ShortcutAction {
    enum class Kind {
        Chord,     // lift current modifiers, send winMods+key as one atomic chord, restore modifiers
        CmdToAlt,  // Cmd+Tab: turn the held Command (Ctrl) into Alt and tap the key (Alt+Tab switcher)
    };
    Kind kind = Kind::Chord;
    uint8_t winMods = 0;     // kMod* bits
    WinKey key;
    bool hasKey = true;
    bool shiftPass = false;  // add Shift to the chord when Shift is physically held
    bool repeatable = false; // auto-repeat re-runs the action (arrows) or is ignored (Cmd+Q)
    const char* desc = "";
};

class MacShortcuts {
public:
    // Look for an override for this key given the held modifiers.
    // Plain Cmd+C -> Ctrl+C needs no rule: Command already *is* Ctrl while held.
    static std::optional<ShortcutAction> find(uint16_t macKey, const ShortcutContext& ctx);
};


// ==========================================================================
// LanguageManager.h
// ==========================================================================
class LanguageManager {
public:
    struct Layout {
        HKL hkl;
        LANGID lang;
        std::wstring code3;  // "ENG"
        std::wstring code2;  // "EN"
        std::wstring name;   // "English (United States)"
    };
    struct Result {
        bool ok = false;
        std::string from, to;  // 3-letter codes for the log
    };

    // All keyboard layouts installed for the current user.
    static std::vector<Layout> installed();
    static std::wstring code3(LANGID lang);
    static std::wstring code2(LANGID lang);
    static std::wstring displayName(LANGID lang);

    // Switch to the next language of Settings::languages relative to the layout that is
    // active in the foreground window. With dryRun nothing is sent (Keyboard Test mode).
    Result toggle(bool dryRun);

    // UI thread: remember the layout of the last foreground window that is not ours.
    void poll();
    HKL lastForeign() const { return lastForeign_; }

    // Set by KeyboardManager: lets the hotkey methods (Win+Space, Alt+Shift, Ctrl+Shift) inject chords.
    std::function<void(uint8_t mods, const WinKey* key)> sendChord;

private:
    static HKL layoutOf(HWND w);
    HKL lastForeign_ = nullptr;
};


// ==========================================================================
// KeyboardManager.h
// ==========================================================================
// What the Keyboard Test window shows for each incoming Mac key event.
struct TraceEvent {
    uint16_t macCode = 0;
    bool down = false;
    bool repeat = false;
    std::string physical;  // "Fn", "Left Command", ...
    std::string detected;  // optional override for the "Detected key" line (mouse events)
    std::string mapped;    // "Language Switch (ENG -> RUS)", "Ctrl+C  (Cmd+C)", ...
    int scan = -1;         // Windows scan code actually injected, -1 = none
    int vk = -1;
    bool ext = false;
};

// Turns Mac key events (from the network thread) into Windows input.
class KeyboardManager {
public:
    explicit KeyboardManager(LanguageManager& lang);

    void onKey(uint16_t macCode, bool down, bool repeat);
    void onAllUp();  // client said so, or the connection dropped: release everything

    // Mouse / trackpad events (relative move in pixels, button 0..4, wheel in 1/120 notch).
    void onMouseMove(int dx, int dy);
    void onMouseButton(int button, bool down);
    void onMouseWheel(int dx, int dy);

    // Keyboard Test mode: translate + trace, but do not inject and do not switch the layout.
    void setDryRun(bool on);
    void setTraceSink(std::function<void(const TraceEvent&)> f);

private:
    void handle(uint16_t code, bool down, bool repeat, const Config& cfg, TraceEvent& t);
    WinKey modifierTarget(uint16_t code, const Config& cfg) const;
    void runAction(const ShortcutAction& a, const ShortcutContext& ctx);
    void doToggle(TraceEvent& t);
    void emitTrace(const TraceEvent& t);
    void releaseHeld(uint16_t code);
    bool isHeld(uint16_t code) const { return held_.count(code) != 0; }

    LanguageManager& lang_;
    Injector inj_;
    std::mutex mu_;
    std::unordered_map<uint16_t, std::vector<WinKey>> held_;  // Mac key -> Windows keys it currently holds down
    bool fnHeld_ = false, fnUsed_ = false, fnToggled_ = false, dry_ = false;
    uint64_t fnDownMs_ = 0;
    std::function<void(const TraceEvent&)> trace_;
};


// ==========================================================================
// NetworkServer.h
// ==========================================================================
class KeyboardManager;

// TCP server: one MacBook client at a time, HMAC challenge-response authentication,
// fixed 4-byte key events (see Protocol.h).
class NetworkServer {
public:
    explicit NetworkServer(KeyboardManager& kb);
    ~NetworkServer();

    bool start(const std::string& bindAddr, uint16_t port, const std::string& secret);
    void stop();

    bool running() const { return running_; }
    std::string clientAddress() const;  // empty when nobody is connected

    std::function<void()> onStatus;  // called from the network thread whenever the state changes

private:
    void acceptLoop(SOCKET listenSock);
    bool handshake(SOCKET s);
    void serve(SOCKET s, const std::string& peer);
    void notify() {
        if (onStatus) onStatus();
    }

    KeyboardManager& kb_;
    SOCKET listen_ = INVALID_SOCKET;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> stop_{false};
    std::string secret_;

    mutable std::mutex mu_;
    std::string client_;
    SOCKET active_ = INVALID_SOCKET;
};


// ==========================================================================
// TrayIcon.h
// ==========================================================================
// System-tray icon that shows the active layout ("EN", "RU") on a coloured badge:
// grey = disabled, blue = waiting for the MacBook, green = MacBook connected.
class TrayIcon {
public:
    enum class State { Disabled, Listening, Connected };

    TrayIcon() = default;
    ~TrayIcon();
    TrayIcon(const TrayIcon&) = delete;
    TrayIcon& operator=(const TrayIcon&) = delete;

    bool create(HWND hwnd, UINT callbackMsg);
    void update(const std::wstring& code2, const std::wstring& tip, State st);
    void readd();  // Explorer restarted ("TaskbarCreated")
    void remove();

private:
    static HICON makeIcon(const std::wstring& text, COLORREF bg, int size);
    void apply(bool add);

    NOTIFYICONDATAW nid_{};
    HICON icon_ = nullptr;
    bool added_ = false;
    bool haveLast_ = false;
    std::wstring lastCode_, lastTip_;
    State lastState_ = State::Disabled;
};


// ==========================================================================
// UI.h
// ==========================================================================
class LanguageManager;
class KeyboardManager;
class NetworkServer;

// Posted by a second instance to the running one: "show your settings window".
constexpr UINT kMsgShowSettings = WM_APP + 5;

namespace UI {
// Creates the tray icon + hidden main window, runs the message loop. Returns the exit code.
int run(HINSTANCE inst, LanguageManager& lang, KeyboardManager& kb, NetworkServer& net, bool showSettings);
}  // namespace UI


// ==========================================================================
// Log.cpp
// ==========================================================================
namespace Log {
namespace {
std::mutex g_mu;
FILE* g_file = nullptr;
std::atomic<bool> g_debug{false};
}  // namespace

void init(const std::wstring& dir) {
    std::lock_guard<std::mutex> lk(g_mu);
    CreateDirectoryW(dir.c_str(), nullptr);
    std::wstring path = dir + L"\\log.txt";

    WIN32_FILE_ATTRIBUTE_DATA fad{};
    if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fad) && fad.nFileSizeLow > 1024 * 1024) {
        MoveFileExW(path.c_str(), (dir + L"\\log.old.txt").c_str(), MOVEFILE_REPLACE_EXISTING);
    }
    g_file = _wfopen(path.c_str(), L"ab");
}

void setDebug(bool on) { g_debug = on; }
bool debugEnabled() { return g_debug; }

void write(Level lvl, const char* fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);

    static const char* names[] = {"DEBUG", "INFO", "WARN", "ERROR"};
    SYSTEMTIME st;
    GetLocalTime(&st);
    char line[1200];
    snprintf(line, sizeof line, "%04d-%02d-%02d %02d:%02d:%02d.%03d [%s] %s\n", st.wYear, st.wMonth, st.wDay,
             st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, names[(int)lvl], msg);

    std::lock_guard<std::mutex> lk(g_mu);
    if (g_file) {
        fputs(line, g_file);
        fflush(g_file);
    }
    OutputDebugStringA(line);
}
}  // namespace Log


// ==========================================================================
// Settings.cpp
// ==========================================================================
namespace {

std::wstring getStr(const std::wstring& path, const wchar_t* sec, const wchar_t* key, const wchar_t* def) {
    wchar_t buf[512];
    GetPrivateProfileStringW(sec, key, def, buf, 512, path.c_str());
    return buf;
}

void putStr(const std::wstring& path, const wchar_t* sec, const wchar_t* key, const std::wstring& v) {
    WritePrivateProfileStringW(sec, key, v.c_str(), path.c_str());
}

void putInt(const std::wstring& path, const wchar_t* sec, const wchar_t* key, int v) {
    putStr(path, sec, key, std::to_wstring(v));
}

std::string randomSecret() {
    unsigned char b[8] = {};
    BCryptGenRandom(nullptr, b, sizeof b, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    static const char* hex = "0123456789abcdef";
    std::string s;
    for (unsigned char c : b) {
        s += hex[c >> 4];
        s += hex[c & 15];
    }
    return s;
}

std::vector<uint16_t> parseLangs(const std::wstring& s) {
    std::vector<uint16_t> out;
    size_t pos = 0;
    while (pos < s.size()) {
        size_t e = s.find(L',', pos);
        if (e == std::wstring::npos) e = s.size();
        std::wstring tok = s.substr(pos, e - pos);
        unsigned long v = wcstoul(tok.c_str(), nullptr, 0);  // base 0: accepts "0x0409"
        if (v != 0 && v <= 0xFFFF) out.push_back((uint16_t)v);
        pos = e + 1;
    }
    return out;
}

std::wstring langsToStr(const std::vector<uint16_t>& v) {
    std::wstring s;
    for (size_t i = 0; i < v.size(); ++i) {
        wchar_t t[16];
        wsprintfW(t, L"0x%04X", (unsigned)v[i]);
        if (i) s += L",";
        s += t;
    }
    return s;
}

}  // namespace

Settings& Settings::instance() {
    static Settings s;
    return s;
}

Settings::Settings() {
    wchar_t appdata[MAX_PATH] = {};
    GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
    dir_ = std::wstring(appdata) + L"\\MacKeyBridge";
    CreateDirectoryW(dir_.c_str(), nullptr);
    path_ = dir_ + L"\\settings.ini";
    cfg_ = std::make_shared<const Config>();
}

std::shared_ptr<const Config> Settings::get() const {
    std::lock_guard<std::mutex> lk(mu_);
    return cfg_;
}

bool Settings::load() {
    const bool existed = GetFileAttributesW(path_.c_str()) != INVALID_FILE_ATTRIBUTES;
    Config c;
    if (existed) {
        const wchar_t* P = path_.c_str();
        auto B = [&](const wchar_t* sec, const wchar_t* key, bool def) {
            return GetPrivateProfileIntW(sec, key, def ? 1 : 0, P) != 0;
        };
        c.macMode = B(L"Keyboard", L"macMode", c.macMode);
        c.commandShortcuts = B(L"Keyboard", L"commandShortcuts", c.commandShortcuts);
        c.rightCmdIsWin = B(L"Keyboard", L"rightCmdIsWin", c.rightCmdIsWin);
        c.macTextNav = B(L"Keyboard", L"macTextNav", c.macTextNav);
        c.optionAsAlt = B(L"Keyboard", L"optionAsAlt", c.optionAsAlt);
        c.isoKeyboard = B(L"Keyboard", L"isoKeyboard", c.isoKeyboard);
        c.fnLanguageSwitch = B(L"Keyboard", L"fnLanguageSwitch", c.fnLanguageSwitch);
        c.fnLayer = B(L"Keyboard", L"fnLayer", c.fnLayer);
        c.fnTapMs = (int)GetPrivateProfileIntW(L"Keyboard", L"fnTapMs", c.fnTapMs, P);

        auto langs = parseLangs(getStr(path_, L"Languages", L"languages", L"0x0409,0x0419"));
        if (langs.size() >= 2) c.languages = langs;
        int m = (int)GetPrivateProfileIntW(L"Languages", L"method", (int)c.method, P);
        c.method = (m >= 0 && m <= 3) ? (SwitchMethod)m : SwitchMethod::Api;

        c.enabled = B(L"Connection", L"enabled", c.enabled);
        c.bindAddress = narrow(getStr(path_, L"Connection", L"bindAddress", L"0.0.0.0"));
        c.port = (int)GetPrivateProfileIntW(L"Connection", L"port", c.port, P);
        c.secret = narrow(getStr(path_, L"Connection", L"secret", L""));

        c.minimizeToTray = B(L"Startup", L"minimizeToTray", c.minimizeToTray);
        c.debug = B(L"Startup", L"debug", c.debug);
    }
    const bool needSave = !existed || c.secret.empty();
    if (c.secret.empty()) c.secret = randomSecret();
    if (c.port < 1 || c.port > 65535) c.port = 47800;

    auto p = std::make_shared<const Config>(c);
    {
        std::lock_guard<std::mutex> lk(mu_);
        cfg_ = p;
    }
    if (needSave) save(c);
    return existed;
}

void Settings::set(Config c) {
    if (c.languages.size() < 2) c.languages = {0x0409, 0x0419};
    if (c.port < 1 || c.port > 65535) c.port = 47800;
    if (c.fnTapMs < 100) c.fnTapMs = 100;
    if (c.bindAddress.empty()) c.bindAddress = "0.0.0.0";
    if (c.secret.empty()) c.secret = randomSecret();

    auto p = std::make_shared<const Config>(c);
    {
        std::lock_guard<std::mutex> lk(mu_);
        cfg_ = p;
    }
    save(c);
    if (onChanged) onChanged();
}

void Settings::save(const Config& c) const {
    const std::wstring& P = path_;
    auto b = [](bool v) { return std::wstring(v ? L"1" : L"0"); };
    putStr(P, L"Keyboard", L"macMode", b(c.macMode));
    putStr(P, L"Keyboard", L"commandShortcuts", b(c.commandShortcuts));
    putStr(P, L"Keyboard", L"rightCmdIsWin", b(c.rightCmdIsWin));
    putStr(P, L"Keyboard", L"macTextNav", b(c.macTextNav));
    putStr(P, L"Keyboard", L"optionAsAlt", b(c.optionAsAlt));
    putStr(P, L"Keyboard", L"isoKeyboard", b(c.isoKeyboard));
    putStr(P, L"Keyboard", L"fnLanguageSwitch", b(c.fnLanguageSwitch));
    putStr(P, L"Keyboard", L"fnLayer", b(c.fnLayer));
    putInt(P, L"Keyboard", L"fnTapMs", c.fnTapMs);

    putStr(P, L"Languages", L"languages", langsToStr(c.languages));
    putInt(P, L"Languages", L"method", (int)c.method);

    putStr(P, L"Connection", L"enabled", b(c.enabled));
    putStr(P, L"Connection", L"bindAddress", widen(c.bindAddress));
    putInt(P, L"Connection", L"port", c.port);
    putStr(P, L"Connection", L"secret", widen(c.secret));

    putStr(P, L"Startup", L"minimizeToTray", b(c.minimizeToTray));
    putStr(P, L"Startup", L"debug", b(c.debug));
}


// ==========================================================================
// KeyMapper.cpp
// ==========================================================================
namespace {

struct Entry {
    uint16_t mac;
    const char* name;
    uint8_t vk;
    uint16_t scan;  // set-1 scan code, 0 = inject by VK only
    bool ext;       // E0 prefix
};

// macOS virtual key codes are physical-position codes, so this table is layout independent.
// Scan codes are constants (not MapVirtualKey) so the result never depends on the active layout.
const Entry kTable[] = {
    // letters
    {0, "A", 'A', 0x1E, false},  {1, "S", 'S', 0x1F, false},  {2, "D", 'D', 0x20, false},
    {3, "F", 'F', 0x21, false},  {4, "H", 'H', 0x23, false},  {5, "G", 'G', 0x22, false},
    {6, "Z", 'Z', 0x2C, false},  {7, "X", 'X', 0x2D, false},  {8, "C", 'C', 0x2E, false},
    {9, "V", 'V', 0x2F, false},  {11, "B", 'B', 0x30, false}, {12, "Q", 'Q', 0x10, false},
    {13, "W", 'W', 0x11, false}, {14, "E", 'E', 0x12, false}, {15, "R", 'R', 0x13, false},
    {16, "Y", 'Y', 0x15, false}, {17, "T", 'T', 0x14, false}, {31, "O", 'O', 0x18, false},
    {32, "U", 'U', 0x16, false}, {34, "I", 'I', 0x17, false}, {35, "P", 'P', 0x19, false},
    {37, "L", 'L', 0x26, false}, {38, "J", 'J', 0x24, false}, {40, "K", 'K', 0x25, false},
    {45, "N", 'N', 0x31, false}, {46, "M", 'M', 0x32, false},
    // digits
    {18, "1", '1', 0x02, false}, {19, "2", '2', 0x03, false}, {20, "3", '3', 0x04, false},
    {21, "4", '4', 0x05, false}, {23, "5", '5', 0x06, false}, {22, "6", '6', 0x07, false},
    {26, "7", '7', 0x08, false}, {28, "8", '8', 0x09, false}, {25, "9", '9', 0x0A, false},
    {29, "0", '0', 0x0B, false},
    // punctuation
    {27, "- (Minus)", VK_OEM_MINUS, 0x0C, false},
    {24, "= (Equal)", VK_OEM_PLUS, 0x0D, false},
    {33, "[ (Left Bracket)", VK_OEM_4, 0x1A, false},
    {30, "] (Right Bracket)", VK_OEM_6, 0x1B, false},
    {41, "; (Semicolon)", VK_OEM_1, 0x27, false},
    {39, "' (Quote)", VK_OEM_7, 0x28, false},
    {42, "\\ (Backslash)", VK_OEM_5, 0x2B, false},
    {43, ", (Comma)", VK_OEM_COMMA, 0x33, false},
    {47, ". (Period)", VK_OEM_PERIOD, 0x34, false},
    {44, "/ (Slash)", VK_OEM_2, 0x35, false},
    {50, "` (Grave)", VK_OEM_3, 0x29, false},
    {10, "ISO Section / 102nd key", VK_OEM_102, 0x56, false},
    // control keys
    {36, "Return", VK_RETURN, 0x1C, false},
    {48, "Tab", VK_TAB, 0x0F, false},
    {49, "Space", VK_SPACE, 0x39, false},
    {51, "Delete (Backspace)", VK_BACK, 0x0E, false},
    {53, "Escape", VK_ESCAPE, 0x01, false},
    // modifiers (default positional mapping; KeyboardManager overrides Cmd/Option by settings)
    {55, "Left Command", VK_LWIN, 0x5B, true},
    {54, "Right Command", VK_RWIN, 0x5C, true},
    {56, "Left Shift", VK_LSHIFT, 0x2A, false},
    {60, "Right Shift", VK_RSHIFT, 0x36, false},
    {58, "Left Option", VK_LMENU, 0x38, false},
    {61, "Right Option", VK_RMENU, 0x38, true},
    {59, "Left Control", VK_LCONTROL, 0x1D, false},
    {62, "Right Control", VK_RCONTROL, 0x1D, true},
    {57, "Caps Lock", VK_CAPITAL, 0x3A, false},
    {63, "Fn", 0, 0, false},
    // function keys
    {122, "F1", VK_F1, 0x3B, false}, {120, "F2", VK_F2, 0x3C, false}, {99, "F3", VK_F3, 0x3D, false},
    {118, "F4", VK_F4, 0x3E, false}, {96, "F5", VK_F5, 0x3F, false},  {97, "F6", VK_F6, 0x40, false},
    {98, "F7", VK_F7, 0x41, false},  {100, "F8", VK_F8, 0x42, false}, {101, "F9", VK_F9, 0x43, false},
    {109, "F10", VK_F10, 0x44, false}, {103, "F11", VK_F11, 0x57, false}, {111, "F12", VK_F12, 0x58, false},
    // Apple extended keyboards: F13/F14/F15 are the PC PrintScreen/ScrollLock/Pause positions
    {105, "F13", VK_SNAPSHOT, 0, false}, {107, "F14", VK_SCROLL, 0, false}, {113, "F15", VK_PAUSE, 0, false},
    {106, "F16", VK_F16, 0, false}, {64, "F17", VK_F17, 0, false}, {79, "F18", VK_F18, 0, false},
    {80, "F19", VK_F19, 0, false},  {90, "F20", VK_F20, 0, false},
    // navigation cluster (external Apple keyboards; on MacBooks reached through Fn)
    {114, "Help (Insert)", VK_INSERT, 0x52, true},
    {115, "Home", VK_HOME, 0x47, true},
    {116, "Page Up", VK_PRIOR, 0x49, true},
    {117, "Forward Delete", VK_DELETE, 0x53, true},
    {119, "End", VK_END, 0x4F, true},
    {121, "Page Down", VK_NEXT, 0x51, true},
    {123, "Left Arrow", VK_LEFT, 0x4B, true},
    {124, "Right Arrow", VK_RIGHT, 0x4D, true},
    {125, "Down Arrow", VK_DOWN, 0x50, true},
    {126, "Up Arrow", VK_UP, 0x48, true},
    {110, "Context Menu", VK_APPS, 0x5D, true},
    // keypad
    {82, "Keypad 0", VK_NUMPAD0, 0x52, false}, {83, "Keypad 1", VK_NUMPAD1, 0x4F, false},
    {84, "Keypad 2", VK_NUMPAD2, 0x50, false}, {85, "Keypad 3", VK_NUMPAD3, 0x51, false},
    {86, "Keypad 4", VK_NUMPAD4, 0x4B, false}, {87, "Keypad 5", VK_NUMPAD5, 0x4C, false},
    {88, "Keypad 6", VK_NUMPAD6, 0x4D, false}, {89, "Keypad 7", VK_NUMPAD7, 0x47, false},
    {91, "Keypad 8", VK_NUMPAD8, 0x48, false}, {92, "Keypad 9", VK_NUMPAD9, 0x49, false},
    {65, "Keypad .", VK_DECIMAL, 0x53, false}, {67, "Keypad *", VK_MULTIPLY, 0x37, false},
    {69, "Keypad +", VK_ADD, 0x4E, false},     {78, "Keypad -", VK_SUBTRACT, 0x4A, false},
    {75, "Keypad /", VK_DIVIDE, 0x35, true},   {76, "Keypad Enter", VK_RETURN, 0x1C, true},
    {71, "Keypad Clear (Num Lock)", VK_NUMLOCK, 0x45, false},
    {81, "Keypad =", VK_OEM_PLUS, 0x0D, false},
    // volume keys of external Apple keyboards (VK injection; they have no scan codes)
    {72, "Volume Up", VK_VOLUME_UP, 0, false},
    {73, "Volume Down", VK_VOLUME_DOWN, 0, false},
    {74, "Mute", VK_VOLUME_MUTE, 0, false},
};

const Entry* findMac(uint16_t mac) {
    for (const Entry& e : kTable)
        if (e.mac == mac) return &e;
    return nullptr;
}

}  // namespace

WinKey KeyMapper::base(uint16_t mac, bool iso) {
    // On ISO MacBooks the top-left key and the key next to Left Shift report swapped codes
    // compared to what Windows expects. The setting lets the user flip them.
    if (iso) {
        if (mac == 50) mac = 10;
        else if (mac == 10) mac = 50;
    }
    const Entry* e = findMac(mac);
    if (!e || e->vk == 0) return {};
    return WinKey{e->vk, e->scan, e->ext};
}

WinKey KeyMapper::media(uint16_t code) {
    if (code < mac::MediaBase) return {};
    switch (code - mac::MediaBase) {  // NX_KEYTYPE_*
        case 0:  return WinKey{VK_VOLUME_UP, 0, false};
        case 1:  return WinKey{VK_VOLUME_DOWN, 0, false};
        case 7:  return WinKey{VK_VOLUME_MUTE, 0, false};
        case 16: return WinKey{VK_MEDIA_PLAY_PAUSE, 0, false};
        case 17:
        case 19: return WinKey{VK_MEDIA_NEXT_TRACK, 0, false};
        case 18:
        case 20: return WinKey{VK_MEDIA_PREV_TRACK, 0, false};
        default: return {};
    }
}

WinKey KeyMapper::byVk(uint8_t vk, bool ext) {
    for (const Entry& e : kTable)
        if (e.vk == vk && e.ext == ext) return WinKey{e.vk, e.scan, e.ext};
    for (const Entry& e : kTable)
        if (e.vk == vk) return WinKey{e.vk, e.scan, e.ext};
    return WinKey{vk, 0, ext};
}

bool KeyMapper::isModifier(uint16_t c) {
    return c == mac::LCmd || c == mac::RCmd || c == mac::LShift || c == mac::RShift || c == mac::LOpt ||
           c == mac::ROpt || c == mac::LCtrl || c == mac::RCtrl;
}

std::string KeyMapper::macName(uint16_t code) {
    if (code >= mac::MediaBase) {
        switch (code - mac::MediaBase) {
            case 0:  return "Media: Volume Up";
            case 1:  return "Media: Volume Down";
            case 7:  return "Media: Mute";
            case 16: return "Media: Play/Pause";
            case 17: return "Media: Next";
            case 18: return "Media: Previous";
            case 19: return "Media: Fast Forward";
            case 20: return "Media: Rewind";
            default: break;
        }
    }
    if (const Entry* e = findMac(code)) return e->name;
    char b[32];
    snprintf(b, sizeof b, "Unknown key 0x%02X", (unsigned)code);
    return b;
}

std::string KeyMapper::winName(const WinKey& k) {
    if (!k.valid()) return "-";
    if (k.scan) {
        wchar_t buf[64] = {};
        LONG lp = (LONG)((LONG)k.scan << 16) | (k.ext ? (1L << 24) : 0L);
        if (GetKeyNameTextW(lp, buf, 64) > 0) return narrow(buf);
    }
    char b[32];
    snprintf(b, sizeof b, "VK 0x%02X", (unsigned)k.vk);
    return b;
}


// ==========================================================================
// Injector.cpp
// ==========================================================================
namespace {
constexpr ULONG_PTR kTag = 0x4D4B4231;  // "MKB1" in dwExtraInfo, marks our own events
}

INPUT Injector::make(const WinKey& k, bool down) {
    INPUT in{};
    in.type = INPUT_KEYBOARD;
    in.ki.dwExtraInfo = kTag;
    if (k.scan) {
        in.ki.wScan = k.scan;
        in.ki.dwFlags = KEYEVENTF_SCANCODE;
    } else {
        in.ki.wVk = k.vk;
    }
    if (k.ext) in.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    if (!down) in.ki.dwFlags |= KEYEVENTF_KEYUP;
    return in;
}

// Unassigned virtual key (0xE8). Tapping it while Win is held stops Windows from treating the
// Win release as a lone "open Start menu" tap (same trick AutoHotkey uses).
INPUT Injector::maskKey(bool down) {
    INPUT in{};
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = 0xE8;
    in.ki.dwExtraInfo = kTag;
    if (!down) in.ki.dwFlags = KEYEVENTF_KEYUP;
    return in;
}

INPUT Injector::makeMouse(DWORD flags, LONG dx, LONG dy, DWORD data) {
    INPUT in{};
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dy = dy;
    in.mi.mouseData = data;
    in.mi.dwFlags = flags;
    in.mi.dwExtraInfo = kTag;
    return in;
}

bool Injector::buttonInput(int button, bool down, INPUT& out) {
    switch (button) {
        case 0: out = makeMouse(down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP, 0, 0, 0); return true;
        case 1: out = makeMouse(down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP, 0, 0, 0); return true;
        case 2: out = makeMouse(down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP, 0, 0, 0); return true;
        case 3: out = makeMouse(down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, 0, 0, XBUTTON1); return true;
        case 4: out = makeMouse(down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, 0, 0, XBUTTON2); return true;
        default: return false;
    }
}

bool Injector::isModifierVk(uint8_t vk) {
    return vk == VK_LSHIFT || vk == VK_RSHIFT || vk == VK_LCONTROL || vk == VK_RCONTROL || vk == VK_LMENU ||
           vk == VK_RMENU || vk == VK_LWIN || vk == VK_RWIN;
}

void Injector::send(std::vector<INPUT>& v) {
    if (dry_ || v.empty()) return;
    UINT n = SendInput((UINT)v.size(), v.data(), sizeof(INPUT));
    if (n != v.size()) {
        LOG_WARN("SendInput injected %u of %u events (error %lu). Target may be elevated or on the secure desktop.",
                 n, (unsigned)v.size(), GetLastError());
    }
}

void Injector::press(const WinKey& k) {
    if (!k.valid()) return;
    Held& h = held_[id(k)];
    if (h.count++ == 0) {
        h.key = k;
        std::vector<INPUT> v{make(k, true)};
        send(v);
    }
}

void Injector::release(const WinKey& k) {
    auto it = held_.find(id(k));
    if (it == held_.end()) return;
    if (--it->second.count <= 0) {
        std::vector<INPUT> v{make(it->second.key, false)};
        held_.erase(it);
        send(v);
    }
}

void Injector::repeat(const WinKey& k) {
    if (!k.valid()) return;
    std::vector<INPUT> v{make(k, true)};
    send(v);
}

void Injector::tap(const WinKey& k) {
    if (!k.valid()) return;
    std::vector<INPUT> v{make(k, true), make(k, false)};
    send(v);
}

void Injector::chord(uint8_t mods, const WinKey* key) {
    std::vector<INPUT> v;
    std::vector<WinKey> saved;
    bool winHeld = false;
    for (const auto& kv : held_) {
        const WinKey& k = kv.second.key;
        if (!isModifierVk(k.vk)) continue;
        saved.push_back(k);
        if (isWinVk(k.vk)) winHeld = true;
    }
    if (winHeld) {
        v.push_back(maskKey(true));
        v.push_back(maskKey(false));
    }
    for (const WinKey& k : saved) v.push_back(make(k, false));

    std::vector<WinKey> mk;
    if (mods & kModWin) mk.push_back(KeyMapper::byVk(VK_LWIN, true));
    if (mods & kModCtrl) mk.push_back(KeyMapper::byVk(VK_LCONTROL));
    if (mods & kModAlt) mk.push_back(KeyMapper::byVk(VK_LMENU));
    if (mods & kModShift) mk.push_back(KeyMapper::byVk(VK_LSHIFT));

    for (const WinKey& m : mk) v.push_back(make(m, true));
    if (key && key->valid()) {
        v.push_back(make(*key, true));
        v.push_back(make(*key, false));
    }
    for (auto it = mk.rbegin(); it != mk.rend(); ++it) v.push_back(make(*it, false));
    for (const WinKey& k : saved) v.push_back(make(k, true));
    send(v);
}

void Injector::mouseMove(int dx, int dy) {
    if (dx == 0 && dy == 0) return;
    std::vector<INPUT> v{makeMouse(MOUSEEVENTF_MOVE, dx, dy, 0)};
    send(v);
}

void Injector::mouseButton(int button, bool down) {
    INPUT in;
    if (button < 0 || button > 4 || !buttonInput(button, down, in)) return;
    if (mouseDown_[button] == down) return;  // ignore duplicate down/up
    mouseDown_[button] = down;
    std::vector<INPUT> v{in};
    send(v);
}

void Injector::mouseWheel(int dx, int dy) {
    std::vector<INPUT> v;
    if (dy != 0) v.push_back(makeMouse(MOUSEEVENTF_WHEEL, 0, 0, (DWORD)(LONG)dy));
    if (dx != 0) v.push_back(makeMouse(MOUSEEVENTF_HWHEEL, 0, 0, (DWORD)(LONG)dx));
    send(v);
}

void Injector::releaseAll() {
    std::vector<INPUT> v;
    bool winHeld = false;
    for (const auto& kv : held_)
        if (isWinVk(kv.second.key.vk)) winHeld = true;
    if (winHeld) {
        v.push_back(maskKey(true));
        v.push_back(maskKey(false));
    }
    for (const auto& kv : held_) v.push_back(make(kv.second.key, false));
    held_.clear();
    for (int b = 0; b < 5; ++b) {  // never leave a mouse button stuck down
        INPUT in;
        if (mouseDown_[b] && buttonInput(b, false, in)) v.push_back(in);
        mouseDown_[b] = false;
    }
    send(v);
}


// ==========================================================================
// MacShortcuts.cpp
// ==========================================================================
namespace {

constexpr uint8_t MM_CMD = 1, MM_OPT = 2, MM_CTRL = 4, MM_SHIFT = 8;  // Mac-side modifier mask

using K = ShortcutAction::Kind;

struct Rule {
    uint16_t mac;
    uint8_t mods;       // exact Mac modifier set required (Shift ignored when shiftPass)
    bool shiftPass;
    K kind;
    uint8_t winMods;
    uint8_t vk;
    bool ext;
    bool repeatable;
    bool nav;           // belongs to the "Mac text navigation" group
    const char* desc;
};

const Rule kRules[] = {
    // --- Command shortcuts that are not simply "Command = Ctrl" ---
    {mac::KQ, MM_CMD, false, K::Chord, kModAlt, VK_F4, false, false, false, "Cmd+Q -> Alt+F4"},
    {mac::KQ, MM_CMD | MM_CTRL, false, K::Chord, kModWin, 'L', false, false, false, "Cmd+Ctrl+Q -> Win+L (lock)"},
    {mac::Tab, MM_CMD, true, K::CmdToAlt, 0, VK_TAB, false, true, false, "Cmd+Tab -> Alt+Tab"},
    {mac::Space, MM_CMD, false, K::Chord, kModWin, 'S', false, false, false, "Cmd+Space -> Win+S (search)"},
    {mac::KM, MM_CMD, false, K::Chord, kModWin, VK_DOWN, true, false, false, "Cmd+M -> Win+Down"},
    {mac::K3, MM_CMD | MM_SHIFT, false, K::Chord, 0, VK_SNAPSHOT, false, false, false, "Cmd+Shift+3 -> PrintScreen"},
    {mac::K4, MM_CMD | MM_SHIFT, false, K::Chord, kModWin | kModShift, 'S', false, false, false,
     "Cmd+Shift+4 -> Win+Shift+S (snip)"},
    {mac::Escape, MM_CMD | MM_OPT, false, K::Chord, kModCtrl | kModShift, VK_ESCAPE, false, false, false,
     "Cmd+Opt+Esc -> Ctrl+Shift+Esc (Task Manager)"},

    // --- Mac text navigation ---
    {mac::Left, MM_CMD, true, K::Chord, 0, VK_HOME, true, true, true, "Cmd+Left -> Home"},
    {mac::Right, MM_CMD, true, K::Chord, 0, VK_END, true, true, true, "Cmd+Right -> End"},
    {mac::Up, MM_CMD, true, K::Chord, kModCtrl, VK_HOME, true, true, true, "Cmd+Up -> Ctrl+Home"},
    {mac::Down, MM_CMD, true, K::Chord, kModCtrl, VK_END, true, true, true, "Cmd+Down -> Ctrl+End"},
    {mac::Left, MM_OPT, true, K::Chord, kModCtrl, VK_LEFT, true, true, true, "Opt+Left -> Ctrl+Left"},
    {mac::Right, MM_OPT, true, K::Chord, kModCtrl, VK_RIGHT, true, true, true, "Opt+Right -> Ctrl+Right"},
    {mac::Backspace, MM_OPT, true, K::Chord, kModCtrl, VK_BACK, false, true, true, "Opt+Backspace -> Ctrl+Backspace"},
};

}  // namespace

std::optional<ShortcutAction> MacShortcuts::find(uint16_t key, const ShortcutContext& c) {
    const uint8_t mods = (uint8_t)((c.cmd ? MM_CMD : 0) | (c.opt ? MM_OPT : 0) | (c.ctrl ? MM_CTRL : 0) |
                                   (c.shift ? MM_SHIFT : 0));
    for (const Rule& r : kRules) {
        if (r.mac != key) continue;
        if (r.nav && !c.nav) continue;
        const uint8_t m = r.shiftPass ? (uint8_t)(mods & ~MM_SHIFT) : mods;
        if (m != r.mods) continue;

        ShortcutAction a;
        a.kind = r.kind;
        a.winMods = r.winMods;
        a.key = KeyMapper::byVk(r.vk, r.ext);
        a.shiftPass = r.shiftPass;
        a.repeatable = r.repeatable;
        a.desc = r.desc;
        return a;
    }
    return std::nullopt;
}


// ==========================================================================
// LanguageManager.cpp
// ==========================================================================
namespace {

LANGID langOf(HKL h) { return (LANGID)((UINT_PTR)h & 0xFFFF); }

std::wstring localeStr(LANGID l, LCTYPE type) {
    wchar_t b[96] = {};
    if (GetLocaleInfoW(MAKELCID(l, SORT_DEFAULT), type, b, 96) == 0) return L"??";
    return b;
}

}  // namespace

std::wstring LanguageManager::code3(LANGID l) {
    std::wstring s = localeStr(l, LOCALE_SISO639LANGNAME2);
    for (auto& c : s) c = (wchar_t)towupper(c);
    return s;
}

std::wstring LanguageManager::code2(LANGID l) {
    std::wstring s = localeStr(l, LOCALE_SISO639LANGNAME);
    for (auto& c : s) c = (wchar_t)towupper(c);
    return s;
}

std::wstring LanguageManager::displayName(LANGID l) { return localeStr(l, LOCALE_SLANGUAGE); }

std::vector<LanguageManager::Layout> LanguageManager::installed() {
    std::vector<Layout> out;
    int n = GetKeyboardLayoutList(0, nullptr);
    if (n <= 0) return out;
    std::vector<HKL> v((size_t)n);
    n = GetKeyboardLayoutList(n, v.data());
    for (int i = 0; i < n; ++i) {
        LANGID l = langOf(v[(size_t)i]);
        out.push_back(Layout{v[(size_t)i], l, code3(l), code2(l), displayName(l)});
    }
    return out;
}

HKL LanguageManager::layoutOf(HWND w) {
    DWORD tid = w ? GetWindowThreadProcessId(w, nullptr) : 0;
    return GetKeyboardLayout(tid);
}

void LanguageManager::poll() {
    HWND fg = GetForegroundWindow();
    if (!fg) return;
    DWORD pid = 0;
    GetWindowThreadProcessId(fg, &pid);
    if (pid == GetCurrentProcessId()) return;  // ignore our own windows (settings, test)
    lastForeign_ = layoutOf(fg);
}

LanguageManager::Result LanguageManager::toggle(bool dryRun) {
    Result r;
    auto cfg = Settings::instance().get();
    const auto& L = cfg->languages;
    if (L.size() < 2) {
        LOG_WARN("Language switch: need at least two languages in settings");
        return r;
    }

    HWND fg = GetForegroundWindow();
    const LANGID cur = langOf(layoutOf(fg));

    // Where are we in the configured list? Exact LANGID first, then primary language.
    int idx = -1;
    for (size_t i = 0; i < L.size() && idx < 0; ++i)
        if (L[i] == cur) idx = (int)i;
    for (size_t i = 0; i < L.size() && idx < 0; ++i)
        if (PRIMARYLANGID(L[i]) == PRIMARYLANGID(cur)) idx = (int)i;
    const LANGID want = L[(size_t)(idx + 1) % L.size()];  // idx == -1 -> first language

    r.from = narrow(code3(cur));
    r.to = narrow(code3(want));

    if (cfg->method != SwitchMethod::Api) {
        // Windows cycles through its own layout list; we only inject the configured system hotkey.
        r.ok = true;
        if (dryRun) return r;
        if (!sendChord) return r;
        if (cfg->method == SwitchMethod::WinSpace) {
            WinKey space = KeyMapper::byVk(VK_SPACE);
            sendChord(kModWin, &space);
        } else if (cfg->method == SwitchMethod::AltShift) {
            sendChord(kModAlt | kModShift, nullptr);
        } else {
            sendChord(kModCtrl | kModShift, nullptr);
        }
        return r;
    }

    HKL target = nullptr;
    const auto list = installed();
    for (const auto& l : list)
        if (l.lang == want) {
            target = l.hkl;
            break;
        }
    if (!target)
        for (const auto& l : list)
            if (PRIMARYLANGID(l.lang) == PRIMARYLANGID(want)) {
                target = l.hkl;
                break;
            }
    if (!target) {
        LOG_WARN("Layout %s is not installed in Windows (Settings > Time & language > Language & region)",
                 r.to.c_str());
        return r;
    }

    r.ok = true;
    if (dryRun) return r;
    if (fg) PostMessageW(fg, WM_INPUTLANGCHANGEREQUEST, 0, (LPARAM)target);
    return r;
}


// ==========================================================================
// KeyboardManager.cpp
// ==========================================================================
namespace {

bool cmdIsCtrl(const Config& c) { return c.macMode && c.commandShortcuts; }

// Fn + key => keys a MacBook does not have.
WinKey fnLayerKey(uint16_t code) {
    switch (code) {
        case mac::Left:      return KeyMapper::byVk(VK_HOME, true);
        case mac::Right:     return KeyMapper::byVk(VK_END, true);
        case mac::Up:        return KeyMapper::byVk(VK_PRIOR, true);
        case mac::Down:      return KeyMapper::byVk(VK_NEXT, true);
        case mac::Backspace: return KeyMapper::byVk(VK_DELETE, true);
        case mac::KI:        return KeyMapper::byVk(VK_INSERT, true);
        default:             return {};
    }
}

}  // namespace

KeyboardManager::KeyboardManager(LanguageManager& lang) : lang_(lang) {
    // Called from inside handle(), i.e. with mu_ already held -> must not lock again.
    lang_.sendChord = [this](uint8_t mods, const WinKey* key) { inj_.chord(mods, key); };
}

void KeyboardManager::setTraceSink(std::function<void(const TraceEvent&)> f) {
    std::lock_guard<std::mutex> lk(mu_);
    trace_ = std::move(f);
}

void KeyboardManager::setDryRun(bool on) {
    std::lock_guard<std::mutex> lk(mu_);
    if (on) {
        inj_.releaseAll();  // do not leave real keys pressed when we stop injecting
        held_.clear();
        fnHeld_ = false;
    }
    dry_ = on;
    inj_.setDryRun(on);
}

void KeyboardManager::onAllUp() {
    std::lock_guard<std::mutex> lk(mu_);
    held_.clear();
    inj_.releaseAll();
    fnHeld_ = fnUsed_ = fnToggled_ = false;
}

void KeyboardManager::emitTrace(const TraceEvent& t) {
    std::function<void(const TraceEvent&)> sink;
    {
        std::lock_guard<std::mutex> lk(mu_);
        sink = trace_;
    }
    if (sink) sink(t);
}

void KeyboardManager::onMouseMove(int dx, int dy) {
    if (dx < -5000 || dx > 5000 || dy < -5000 || dy > 5000) return;  // sanity limit
    std::lock_guard<std::mutex> lk(mu_);
    inj_.mouseMove(dx, dy);
}

void KeyboardManager::onMouseButton(int button, bool down) {
    static const char* names[] = {"Left", "Right", "Middle", "Back", "Forward"};
    if (button < 0 || button > 4) return;
    {
        std::lock_guard<std::mutex> lk(mu_);
        inj_.mouseButton(button, down);
    }
    LOG_DEBUG("Mouse %s button %s", names[button], down ? "DOWN" : "UP");
    TraceEvent t;
    t.down = down;
    t.physical = std::string("Mouse ") + names[button] + " button";
    t.detected = std::string("Trackpad / mouse button ") + (down ? "DOWN" : "UP");
    t.mapped = std::string(names[button]) + " mouse button " + (down ? "down" : "up");
    emitTrace(t);
}

void KeyboardManager::onMouseWheel(int dx, int dy) {
    if (dx == 0 && dy == 0) return;
    {
        std::lock_guard<std::mutex> lk(mu_);
        inj_.mouseWheel(dx, dy);
    }
    TraceEvent t;
    t.physical = "Scroll (two-finger / wheel)";
    t.detected = "dx=" + std::to_string(dx) + "  dy=" + std::to_string(dy);
    t.mapped = dy != 0 ? (dy > 0 ? "Wheel up" : "Wheel down") : (dx > 0 ? "Wheel right" : "Wheel left");
    emitTrace(t);
}

void KeyboardManager::onKey(uint16_t code, bool down, bool repeat) {
    auto cfg = Settings::instance().get();
    TraceEvent t;
    t.macCode = code;
    t.down = down;
    t.repeat = repeat;
    t.physical = KeyMapper::macName(code);

    std::function<void(const TraceEvent&)> sink;
    {
        std::lock_guard<std::mutex> lk(mu_);
        handle(code, down, repeat, *cfg, t);
        sink = trace_;
    }
    LOG_DEBUG("%s %s%s -> %s", t.physical.c_str(), down ? "DOWN" : "UP", repeat ? " (repeat)" : "",
              t.mapped.c_str());
    if (sink) sink(t);
}

WinKey KeyboardManager::modifierTarget(uint16_t code, const Config& c) const {
    using namespace mac;
    switch (code) {
        case LCmd:
            return cmdIsCtrl(c) ? KeyMapper::byVk(VK_LCONTROL) : KeyMapper::byVk(VK_LWIN, true);
        case RCmd:
            if (!cmdIsCtrl(c) || c.rightCmdIsWin) return KeyMapper::byVk(VK_RWIN, true);
            return KeyMapper::byVk(VK_RCONTROL, true);
        case LOpt:   return c.optionAsAlt ? KeyMapper::byVk(VK_LMENU) : KeyMapper::byVk(VK_LWIN, true);
        case ROpt:   return c.optionAsAlt ? KeyMapper::byVk(VK_RMENU, true) : KeyMapper::byVk(VK_RWIN, true);
        case LCtrl:  return KeyMapper::byVk(VK_LCONTROL);
        case RCtrl:  return KeyMapper::byVk(VK_RCONTROL, true);
        case LShift: return KeyMapper::byVk(VK_LSHIFT);
        case RShift: return KeyMapper::byVk(VK_RSHIFT);
        default:     return {};
    }
}

void KeyboardManager::releaseHeld(uint16_t code) {
    auto it = held_.find(code);
    if (it == held_.end()) return;
    for (const WinKey& k : it->second) inj_.release(k);
    held_.erase(it);
}

void KeyboardManager::doToggle(TraceEvent& t) {
    LOG_INFO("Fn pressed");
    auto r = lang_.toggle(dry_);
    if (r.ok) {
        LOG_INFO("Language: %s -> %s%s", r.from.c_str(), r.to.c_str(), dry_ ? " (test mode, not applied)" : "");
        t.mapped = "Language Switch (" + r.from + " -> " + r.to + ")";
    } else {
        t.mapped = "Language Switch (failed, see log)";
    }
}

void KeyboardManager::runAction(const ShortcutAction& a, const ShortcutContext& ctx) {
    if (a.kind == ShortcutAction::Kind::Chord) {
        uint8_t mods = a.winMods;
        if (a.shiftPass && ctx.shift) mods |= kModShift;
        inj_.chord(mods, a.hasKey ? &a.key : nullptr);
        return;
    }

    // Cmd+Tab: Windows' Alt+Tab switcher stays open while Alt is held, so turn the held Command
    // key (currently Ctrl) into Alt until it is released, and tap Tab on top of it.
    const WinKey alt = KeyMapper::byVk(VK_LMENU);
    const uint16_t cmdCode = isHeld(mac::LCmd) ? mac::LCmd : mac::RCmd;
    std::vector<WinKey>& hv = held_[cmdCode];
    if (hv.empty() || !(hv.front() == alt)) {
        for (const WinKey& k : hv) inj_.release(k);
        hv.assign(1, alt);
        inj_.press(alt);
    }
    inj_.tap(a.key);
}

void KeyboardManager::handle(uint16_t code, bool down, bool repeat, const Config& cfg, TraceEvent& t) {
    using namespace mac;

    auto setWin = [&](const WinKey& k, const std::string& prefix = std::string()) {
        t.scan = k.scan ? (int)k.scan : -1;
        t.vk = k.vk;
        t.ext = k.ext;
        t.mapped = prefix + KeyMapper::winName(k);
    };

    // ---------------------------------------------------------------- Fn
    // Fn is never injected into Windows. A tap switches the language; Fn+key is a layer.
    if (code == Fn) {
        if (down) {
            if (!fnHeld_) {
                fnHeld_ = true;
                fnUsed_ = false;
                fnToggled_ = false;
                fnDownMs_ = GetTickCount64();
                if (cfg.fnLanguageSwitch && !cfg.fnLayer) {  // immediate mode: switch on press
                    fnUsed_ = true;
                    fnToggled_ = true;
                    doToggle(t);
                }
            }
            if (t.mapped.empty()) {
                t.mapped = !cfg.fnLanguageSwitch ? "Fn (no action)"
                           : cfg.fnLayer         ? "Fn (tap = Language Switch, Fn+key = layer)"
                                                 : "Language Switch";
            }
        } else if (fnHeld_) {
            fnHeld_ = false;
            const bool tap = !fnUsed_ && (GetTickCount64() - fnDownMs_) <= (uint64_t)cfg.fnTapMs;
            if (cfg.fnLanguageSwitch && cfg.fnLayer && tap) {
                doToggle(t);
            } else if (!fnToggled_) {
                t.mapped = fnUsed_ ? "Fn released (was used as layer key)" : "Fn released (held too long, no switch)";
            }
        }
        if (t.mapped.empty()) t.mapped = "Fn";
        return;
    }

    // ---------------------------------------------------------------- media keys (NX_KEYTYPE_*)
    if (code >= MediaBase) {
        const WinKey k = KeyMapper::media(code);
        if (!k.valid()) {
            t.mapped = "(unmapped media key)";
            return;
        }
        setWin(k);
        if (down) {
            if (fnHeld_) fnUsed_ = true;
            inj_.tap(k);  // the client sends media keys as repeated downs only
        }
        return;
    }

    // ---------------------------------------------------------------- Caps Lock: one tap per Mac event
    if (code == Caps) {
        const WinKey k = KeyMapper::byVk(VK_CAPITAL);
        setWin(k, "Caps Lock -> ");
        if (down) inj_.tap(k);
        return;
    }

    // ---------------------------------------------------------------- modifiers
    if (KeyMapper::isModifier(code)) {
        const WinKey k = modifierTarget(code, cfg);
        setWin(k, t.physical + " -> ");
        if (down) {
            if (!isHeld(code)) {
                inj_.press(k);
                held_[code] = {k};
            }
        } else {
            releaseHeld(code);
        }
        return;
    }

    // ---------------------------------------------------------------- regular keys
    const WinKey wk = KeyMapper::base(code, cfg.isoKeyboard);

    if (!down) {
        if (wk.valid()) setWin(wk);
        releaseHeld(code);
        return;
    }

    auto it = held_.find(code);
    if (it != held_.end()) {  // auto-repeat of a key we are holding (Windows does not repeat injected keys itself)
        for (const WinKey& k : it->second) inj_.repeat(k);
        setWin(it->second.front());
        return;
    }

    ShortcutContext ctx;
    ctx.cmd = cmdIsCtrl(cfg) && (isHeld(LCmd) || (!cfg.rightCmdIsWin && isHeld(RCmd)));
    ctx.opt = cfg.macMode && cfg.optionAsAlt && (isHeld(LOpt) || isHeld(ROpt));
    ctx.ctrl = isHeld(LCtrl) || isHeld(RCtrl);
    ctx.shift = isHeld(LShift) || isHeld(RShift);
    ctx.nav = cfg.macMode && cfg.macTextNav;

    if (fnHeld_) {
        fnUsed_ = true;
        if (cfg.fnLayer) {
            const WinKey lk = fnLayerKey(code);
            if (lk.valid()) {
                inj_.press(lk);
                held_[code] = {lk};
                setWin(lk, "Fn+" + t.physical + " -> ");
                return;
            }
        }
    }

    if (cfg.macMode) {
        if (auto act = MacShortcuts::find(code, ctx)) {
            t.mapped = act->desc;
            if (!repeat || act->repeatable) {
                if (!repeat) LOG_INFO("%s", act->desc);
                runAction(*act, ctx);
            }
            return;
        }
    }

    if (!wk.valid()) {
        t.mapped = "(unmapped key)";
        return;
    }
    inj_.press(wk);
    held_[code] = {wk};
    setWin(wk);
    if (ctx.cmd) t.mapped = "Ctrl+" + KeyMapper::winName(wk) + "   (Cmd+" + t.physical + ")";
}


// ==========================================================================
// NetworkServer.cpp
// ==========================================================================
namespace {

bool hmacSha256(const std::string& key, const uint8_t* data, size_t len, uint8_t out[32]) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE h = nullptr;
    bool ok = false;
    if (key.empty()) return false;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG) == 0) {
        if (BCryptCreateHash(alg, &h, nullptr, 0, (PUCHAR)key.data(), (ULONG)key.size(), 0) == 0) {
            if (BCryptHashData(h, (PUCHAR)data, (ULONG)len, 0) == 0 && BCryptFinishHash(h, out, 32, 0) == 0) ok = true;
            BCryptDestroyHash(h);
        }
        BCryptCloseAlgorithmProvider(alg, 0);
    }
    return ok;
}

bool sendAll(SOCKET s, const uint8_t* p, int n) {
    while (n > 0) {
        int r = send(s, (const char*)p, n, 0);
        if (r <= 0) return false;
        p += r;
        n -= r;
    }
    return true;
}

bool recvAll(SOCKET s, uint8_t* p, int n) {
    while (n > 0) {
        int r = recv(s, (char*)p, n, 0);  // SO_RCVTIMEO makes this fail when pings stop arriving
        if (r <= 0) return false;
        p += r;
        n -= r;
    }
    return true;
}

}  // namespace

NetworkServer::NetworkServer(KeyboardManager& kb) : kb_(kb) {}
NetworkServer::~NetworkServer() { stop(); }

std::string NetworkServer::clientAddress() const {
    std::lock_guard<std::mutex> lk(mu_);
    return client_;
}

bool NetworkServer::start(const std::string& bindAddr, uint16_t port, const std::string& secret) {
    stop();
    secret_ = secret;

    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) {
        LOG_ERROR("socket() failed: %d", WSAGetLastError());
        return false;
    }
    BOOL excl = TRUE;  // do not let another process share/hijack the port
    setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char*)&excl, sizeof excl);

    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    if (inet_pton(AF_INET, bindAddr.c_str(), &a.sin_addr) != 1) {
        LOG_ERROR("Invalid listen address '%s'", bindAddr.c_str());
        closesocket(s);
        return false;
    }
    if (::bind(s, (sockaddr*)&a, sizeof a) == SOCKET_ERROR || listen(s, 2) == SOCKET_ERROR) {
        LOG_ERROR("Cannot listen on %s:%u (WSA error %d) - is the port already in use?", bindAddr.c_str(),
                  (unsigned)port, WSAGetLastError());
        closesocket(s);
        return false;
    }

    listen_ = s;
    stop_ = false;
    running_ = true;
    thread_ = std::thread(&NetworkServer::acceptLoop, this, s);
    LOG_INFO("Listening on %s:%u", bindAddr.c_str(), (unsigned)port);
    notify();
    return true;
}

void NetworkServer::stop() {
    if (!running_ && !thread_.joinable()) return;
    stop_ = true;
    {
        std::lock_guard<std::mutex> lk(mu_);
        if (active_ != INVALID_SOCKET) shutdown(active_, SD_BOTH);  // wakes the blocked recv()
    }
    if (listen_ != INVALID_SOCKET) {
        closesocket(listen_);
        listen_ = INVALID_SOCKET;
    }
    if (thread_.joinable()) thread_.join();
    running_ = false;
    LOG_INFO("Server stopped");
    notify();
}

void NetworkServer::acceptLoop(SOCKET ls) {
    while (!stop_) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(ls, &fds);
        timeval tv{0, 300 * 1000};
        int r = select(0, &fds, nullptr, nullptr, &tv);
        if (r == SOCKET_ERROR) {
            if (stop_) break;
            Sleep(50);
            continue;
        }
        if (r == 0) continue;

        sockaddr_in pa{};
        int len = sizeof pa;
        SOCKET c = accept(ls, (sockaddr*)&pa, &len);
        if (c == INVALID_SOCKET) continue;

        char ip[64] = {};
        inet_ntop(AF_INET, &pa.sin_addr, ip, sizeof ip);

        BOOL nodelay = TRUE;  // latency: never wait to coalesce tiny packets
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof nodelay);
        BOOL keep = TRUE;
        setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, (const char*)&keep, sizeof keep);
        DWORD tmo = 3000;  // the client pings every second; silence for 3 s = dead link
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tmo, sizeof tmo);
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tmo, sizeof tmo);

        if (handshake(c)) {
            SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
            serve(c, ip);
            SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_NORMAL);
        } else {
            LOG_WARN("Rejected connection from %s (bad secret or protocol)", ip);
        }
        closesocket(c);
    }
}

bool NetworkServer::handshake(SOCKET s) {
    uint8_t nonce[proto::kNonceLen];
    if (BCryptGenRandom(nullptr, nonce, (ULONG)sizeof nonce, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return false;

    uint8_t msg[1 + proto::kNonceLen];
    msg[0] = proto::kChallenge;
    memcpy(msg + 1, nonce, sizeof nonce);
    if (!sendAll(s, msg, (int)sizeof msg)) return false;

    uint8_t resp[2 + proto::kMacLen];
    if (!recvAll(s, resp, (int)sizeof resp)) return false;
    if (resp[0] != proto::kAuth) return false;
    if (resp[1] != proto::kVersion) {
        const uint8_t fail[2] = {proto::kAuthFail, 2};  // 2 = version mismatch
        sendAll(s, fail, 2);
        return false;
    }

    uint8_t expect[proto::kMacLen];
    if (!hmacSha256(secret_, nonce, sizeof nonce, expect)) return false;
    uint8_t diff = 0;  // constant-time compare
    for (size_t i = 0; i < proto::kMacLen; ++i) diff |= (uint8_t)(expect[i] ^ resp[2 + i]);
    if (diff != 0) {
        const uint8_t fail[2] = {proto::kAuthFail, 1};  // 1 = bad secret
        sendAll(s, fail, 2);
        Sleep(500);  // slow down guessing
        return false;
    }
    const uint8_t ok = proto::kAuthOk;
    return sendAll(s, &ok, 1);
}

void NetworkServer::serve(SOCKET s, const std::string& peer) {
    {
        std::lock_guard<std::mutex> lk(mu_);
        client_ = peer;
        active_ = s;
    }
    LOG_INFO("Connected to MacBook (%s)", peer.c_str());
    notify();

    uint8_t ev[proto::kMaxEventSize];
    bool bad = false;
    while (!stop_ && !bad) {
        if (!recvAll(s, ev, 1)) break;
        const size_t len = proto::eventLength(ev[0]);
        if (len == 0) {
            LOG_WARN("Unknown packet type 0x%02X from %s, dropping connection", ev[0], peer.c_str());
            break;
        }
        if (len > 1 && !recvAll(s, ev + 1, (int)len - 1)) break;

        switch (ev[0]) {
            case proto::kKeyDown:
                kb_.onKey((uint16_t)(ev[2] | (ev[3] << 8)), true, (ev[1] & proto::kFlagRepeat) != 0);
                break;
            case proto::kKeyUp:
                kb_.onKey((uint16_t)(ev[2] | (ev[3] << 8)), false, false);
                break;
            case proto::kAllUp:
                kb_.onAllUp();
                break;
            case proto::kPing:
                break;
            case proto::kMouseMove:
                kb_.onMouseMove((int16_t)(ev[1] | (ev[2] << 8)), (int16_t)(ev[3] | (ev[4] << 8)));
                break;
            case proto::kMouseButton:
                kb_.onMouseButton(ev[1], ev[2] != 0);
                break;
            case proto::kMouseWheel:
                kb_.onMouseWheel((int16_t)(ev[1] | (ev[2] << 8)), (int16_t)(ev[3] | (ev[4] << 8)));
                break;
            default:
                bad = true;
                break;
        }
    }
    kb_.onAllUp();  // never leave keys stuck after a disconnect
    {
        std::lock_guard<std::mutex> lk(mu_);
        client_.clear();
        active_ = INVALID_SOCKET;
    }
    LOG_INFO("MacBook disconnected (%s)", peer.c_str());
    notify();
}


// ==========================================================================
// TrayIcon.cpp
// ==========================================================================
namespace {
// Portable (MSVC + MinGW) bounded copy into the fixed szTip buffer.
void setTip(NOTIFYICONDATAW& n, const std::wstring& t) {
    const size_t maxc = sizeof(n.szTip) / sizeof(n.szTip[0]) - 1;
    const size_t c = t.size() < maxc ? t.size() : maxc;
    wmemcpy(n.szTip, t.c_str(), c);
    n.szTip[c] = 0;
}
}  // namespace

TrayIcon::~TrayIcon() { remove(); }

HICON TrayIcon::makeIcon(const std::wstring& text, COLORREF bg, int sz) {
    HDC screen = GetDC(nullptr);
    HDC dc = CreateCompatibleDC(screen);

    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = sz;
    bi.bmiHeader.biHeight = -sz;  // top-down
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP color = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);  // zero-filled = transparent
    HGDIOBJ oldBmp = SelectObject(dc, color);

    HBRUSH br = CreateSolidBrush(bg);
    HGDIOBJ oldBr = SelectObject(dc, br);
    HGDIOBJ oldPen = SelectObject(dc, GetStockObject(NULL_PEN));
    RoundRect(dc, 0, 0, sz + 1, sz + 1, sz / 4, sz / 4);
    SelectObject(dc, oldPen);
    SelectObject(dc, oldBr);
    DeleteObject(br);

    HFONT font = CreateFontW(-(sz * 62 / 100), 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                             OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                             DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    HGDIOBJ oldFont = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(255, 255, 255));
    RECT rc{0, 0, sz, sz};
    DrawTextW(dc, text.c_str(), -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(dc, oldFont);
    DeleteObject(font);
    GdiFlush();

    // GDI leaves alpha = 0; make every drawn pixel opaque, keep the rounded corners transparent.
    uint32_t* px = (uint32_t*)bits;
    for (int i = 0; i < sz * sz; ++i)
        if (px[i] & 0x00FFFFFF) px[i] |= 0xFF000000;

    std::vector<uint8_t> zeros((size_t)(((sz + 15) / 16) * 2) * (size_t)sz, 0);
    HBITMAP mask = CreateBitmap(sz, sz, 1, 1, zeros.data());

    ICONINFO ii{};
    ii.fIcon = TRUE;
    ii.hbmMask = mask;
    ii.hbmColor = color;
    HICON icon = CreateIconIndirect(&ii);

    SelectObject(dc, oldBmp);
    DeleteObject(color);
    DeleteObject(mask);
    DeleteDC(dc);
    ReleaseDC(nullptr, screen);
    return icon;
}

bool TrayIcon::create(HWND hwnd, UINT callbackMsg) {
    nid_ = {};
    nid_.cbSize = sizeof nid_;
    nid_.hWnd = hwnd;
    nid_.uID = 1;
    nid_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid_.uCallbackMessage = callbackMsg;
    icon_ = makeIcon(L"..", RGB(110, 110, 110), GetSystemMetrics(SM_CXSMICON));
    nid_.hIcon = icon_;
    setTip(nid_, L"MacKeyBridge");
    added_ = Shell_NotifyIconW(NIM_ADD, &nid_) != FALSE;
    return added_;
}

void TrayIcon::apply(bool add) {
    if (!nid_.hWnd) return;
    added_ = Shell_NotifyIconW(add ? NIM_ADD : NIM_MODIFY, &nid_) != FALSE;
}

void TrayIcon::update(const std::wstring& code2, const std::wstring& tip, State st) {
    if (!nid_.hWnd) return;
    if (haveLast_ && st == lastState_ && code2 == lastCode_ && tip == lastTip_) return;
    haveLast_ = true;
    lastState_ = st;
    lastCode_ = code2;
    lastTip_ = tip;

    COLORREF bg = st == State::Connected ? RGB(40, 150, 70)
                  : st == State::Listening ? RGB(45, 105, 200)
                                           : RGB(110, 110, 110);
    HICON ni = makeIcon(code2, bg, GetSystemMetrics(SM_CXSMICON));
    HICON old = icon_;
    icon_ = ni;
    nid_.hIcon = ni;
    setTip(nid_, tip);
    apply(!added_);
    if (old) DestroyIcon(old);
}

void TrayIcon::readd() {
    if (!nid_.hWnd) return;
    apply(true);
}

void TrayIcon::remove() {
    if (nid_.hWnd && added_) Shell_NotifyIconW(NIM_DELETE, &nid_);
    added_ = false;
    nid_.hWnd = nullptr;
    if (icon_) {
        DestroyIcon(icon_);
        icon_ = nullptr;
    }
}


// ==========================================================================
// UI.cpp
// ==========================================================================
namespace {

constexpr UINT WM_TRAY = WM_APP + 1;    // tray icon callback
constexpr UINT WM_STATUS = WM_APP + 2;  // network state changed
constexpr UINT WM_TRACE = WM_APP + 3;   // lParam = heap TraceEvent*

enum : int { ID_ENABLE = 100, ID_DISABLE, ID_SETTINGS, ID_TEST, ID_AUTOSTART, ID_EXIT };

enum : int {
    IDC_TAB = 200,
    IDC_MACMODE, IDC_CMDSC, IDC_RCMDWIN, IDC_TEXTNAV, IDC_OPTALT, IDC_FNLANG, IDC_FNLAYER, IDC_ISO,
    IDC_LANG1, IDC_LANG2, IDC_LANG3, IDC_METHOD, IDC_CURLANG, IDC_DETECT,
    IDC_ADDR, IDC_PORT, IDC_SECRET, IDC_STATUS, IDC_LOCALIPS, IDC_CMDLINE,
    IDC_AUTOSTART, IDC_MINTRAY, IDC_DEBUG,
    IDC_SAVE, IDC_CLOSE, IDC_OPENTEST,
    IDC_DRYRUN, IDC_PHYS, IDC_DET, IDC_SCAN, IDC_VK, IDC_MAPPED, IDC_LOG
};

struct AppState {
    HINSTANCE inst = nullptr;
    HWND main = nullptr, settings = nullptr, test = nullptr, tab = nullptr;
    LanguageManager* lang = nullptr;
    KeyboardManager* kb = nullptr;
    NetworkServer* net = nullptr;
    TrayIcon tray;
    HFONT font = nullptr, bigFont = nullptr;
    HBRUSH white = nullptr;
    std::string lastNetKey;
    UINT taskbarCreated = 0;
    int dpi = 96;
    std::vector<std::pair<HWND, int>> pages;  // control -> settings tab index
    std::vector<std::string> ips;
} S;

int sc(int v) { return MulDiv(v, S.dpi, 96); }

HWND ctl(HWND parent, const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int w, int h, int id,
         DWORD ex = 0) {
    HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, sc(x), sc(y), sc(w), sc(h), parent,
                             (HMENU)(INT_PTR)id, S.inst, nullptr);
    if (c && S.font) SendMessageW(c, WM_SETFONT, (WPARAM)S.font, TRUE);
    return c;
}

// ------------------------------------------------------------------ autostart (HKCU\...\Run, no admin needed)
const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

bool autostartEnabled() {
    return RegGetValueW(HKEY_CURRENT_USER, kRunKey, L"MacKeyBridge", RRF_RT_REG_SZ, nullptr, nullptr, nullptr) ==
           ERROR_SUCCESS;
}

void setAutostart(bool on) {
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &k) != ERROR_SUCCESS) return;
    if (on) {
        wchar_t exe[MAX_PATH] = {};
        GetModuleFileNameW(nullptr, exe, MAX_PATH);
        std::wstring v = L"\"" + std::wstring(exe) + L"\"";
        RegSetValueExW(k, L"MacKeyBridge", 0, REG_SZ, (const BYTE*)v.c_str(), (DWORD)((v.size() + 1) * sizeof(wchar_t)));
    } else {
        RegDeleteValueW(k, L"MacKeyBridge");
    }
    RegCloseKey(k);
}

// ------------------------------------------------------------------ helpers
std::vector<std::string> localIPv4() {
    std::vector<std::string> out;
    char host[256] = {};
    if (gethostname(host, sizeof host) != 0) return out;
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = nullptr;
    if (getaddrinfo(host, nullptr, &hints, &res) != 0) return out;
    for (addrinfo* p = res; p; p = p->ai_next) {
        char ip[64] = {};
        inet_ntop(AF_INET, &((sockaddr_in*)p->ai_addr)->sin_addr, ip, sizeof ip);
        std::string s = ip;
        if (s.rfind("169.254.", 0) == 0 || s.rfind("127.", 0) == 0) continue;
        if (std::find(out.begin(), out.end(), s) == out.end()) out.push_back(s);
    }
    freeaddrinfo(res);
    return out;
}

std::wstring statusText() {
    auto c = Settings::instance().get();
    if (!c->enabled) return L"Disabled";
    if (!S.net->running()) return L"Server not running (port in use? see log)";
    std::string cl = S.net->clientAddress();
    if (!cl.empty()) return L"Connected: " + widen(cl);
    return L"Listening on " + widen(c->bindAddress) + L":" + std::to_wstring(c->port) + L" - waiting for MacBook";
}

HKL currentForeignLayout() {
    HKL h = S.lang->lastForeign();
    return h ? h : GetKeyboardLayout(0);
}


void refreshSettingsStatus() {
    if (!S.settings) return;
    SetDlgItemTextW(S.settings, IDC_STATUS, statusText().c_str());
    LANGID l = langOf(currentForeignLayout());
    std::wstring t = L"Current Windows layout: " + LanguageManager::code3(l) + L"  (" +
                     LanguageManager::displayName(l) + L")";
    SetDlgItemTextW(S.settings, IDC_CURLANG, t.c_str());
}

void refreshTray() {
    if (!S.lang) return;
    S.lang->poll();
    auto c = Settings::instance().get();
    LANGID l = langOf(currentForeignLayout());
    TrayIcon::State st = !c->enabled                   ? TrayIcon::State::Disabled
                         : S.net->clientAddress().empty() ? TrayIcon::State::Listening
                                                          : TrayIcon::State::Connected;
    std::wstring tip = L"MacKeyBridge - " + LanguageManager::code3(l) + L" - " + statusText();
    S.tray.update(LanguageManager::code2(l), tip, st);
    refreshSettingsStatus();
}

void applyConfig() {
    auto c = Settings::instance().get();
    Log::setDebug(c->debug);
    const std::string key = c->bindAddress + ":" + std::to_string(c->port) + "/" + c->secret;
    if (c->enabled) {
        if (!S.net->running() || key != S.lastNetKey) {
            S.lastNetKey = key;
            if (!S.net->start(c->bindAddress, (uint16_t)c->port, c->secret)) LOG_ERROR("Server failed to start");
        }
    } else {
        S.net->stop();  // closes the client; the Mac side then passes keys through to macOS again
        S.lastNetKey.clear();
    }
    refreshTray();
}

// ------------------------------------------------------------------ language combo boxes
void fillLangCombo(HWND cb, bool optional, uint16_t current) {
    SendMessageW(cb, CB_RESETCONTENT, 0, 0);
    int sel = -1;
    if (optional) {
        int i = (int)SendMessageW(cb, CB_ADDSTRING, 0, (LPARAM)L"(none)");
        SendMessageW(cb, CB_SETITEMDATA, (WPARAM)i, 0);
        if (current == 0) sel = i;
    }
    std::vector<uint16_t> seen;
    auto add = [&](uint16_t lang, const std::wstring& text) {
        if (std::find(seen.begin(), seen.end(), lang) != seen.end()) return;
        seen.push_back(lang);
        int i = (int)SendMessageW(cb, CB_ADDSTRING, 0, (LPARAM)text.c_str());
        SendMessageW(cb, CB_SETITEMDATA, (WPARAM)i, (LPARAM)lang);
        if (lang == current) sel = i;
    };
    for (const auto& l : LanguageManager::installed()) add(l.lang, l.name + L" [" + l.code3 + L"]");
    if (current != 0)
        add(current, LanguageManager::displayName(current) + L" [" + LanguageManager::code3(current) +
                         L"] (not installed)");
    SendMessageW(cb, CB_SETCURSEL, (WPARAM)(sel < 0 ? 0 : sel), 0);
}

uint16_t comboLang(HWND h, int id) {
    HWND cb = GetDlgItem(h, id);
    int i = (int)SendMessageW(cb, CB_GETCURSEL, 0, 0);
    if (i < 0) return 0;
    return (uint16_t)SendMessageW(cb, CB_GETITEMDATA, (WPARAM)i, 0);
}

std::wstring dlgText(HWND h, int id) {
    wchar_t b[256] = {};
    GetDlgItemTextW(h, id, b, 256);
    return b;
}

void updateCmdline(HWND h) {
    std::wstring ip = S.ips.empty() ? L"<PC-IP>" : widen(S.ips[0]);
    std::wstring s = L"mackeybridge-client --host " + ip + L" --port " + dlgText(h, IDC_PORT) + L" --secret " +
                     dlgText(h, IDC_SECRET);
    SetDlgItemTextW(h, IDC_CMDLINE, s.c_str());
}

// ------------------------------------------------------------------ settings window
void loadUi(HWND h) {
    const Config c = *Settings::instance().get();
    auto chk = [&](int id, bool v) { CheckDlgButton(h, id, v ? BST_CHECKED : BST_UNCHECKED); };
    chk(IDC_MACMODE, c.macMode);
    chk(IDC_CMDSC, c.commandShortcuts);
    chk(IDC_RCMDWIN, c.rightCmdIsWin);
    chk(IDC_TEXTNAV, c.macTextNav);
    chk(IDC_OPTALT, c.optionAsAlt);
    chk(IDC_FNLANG, c.fnLanguageSwitch);
    chk(IDC_FNLAYER, c.fnLayer);
    chk(IDC_ISO, c.isoKeyboard);

    fillLangCombo(GetDlgItem(h, IDC_LANG1), false, c.languages.size() > 0 ? c.languages[0] : 0x0409);
    fillLangCombo(GetDlgItem(h, IDC_LANG2), false, c.languages.size() > 1 ? c.languages[1] : 0x0419);
    fillLangCombo(GetDlgItem(h, IDC_LANG3), true, c.languages.size() > 2 ? c.languages[2] : 0);
    SendMessageW(GetDlgItem(h, IDC_METHOD), CB_SETCURSEL, (WPARAM)(int)c.method, 0);

    SetDlgItemTextW(h, IDC_ADDR, widen(c.bindAddress).c_str());
    SetDlgItemTextW(h, IDC_PORT, std::to_wstring(c.port).c_str());
    SetDlgItemTextW(h, IDC_SECRET, widen(c.secret).c_str());

    chk(IDC_AUTOSTART, autostartEnabled());
    chk(IDC_MINTRAY, c.minimizeToTray);
    chk(IDC_DEBUG, c.debug);

    std::wstring ips;
    for (const auto& ip : S.ips) ips += (ips.empty() ? L"" : L", ") + widen(ip);
    SetDlgItemTextW(h, IDC_LOCALIPS, ips.empty() ? L"(not detected)" : ips.c_str());
    updateCmdline(h);
    refreshSettingsStatus();
}

bool saveUi(HWND h) {
    Config c = *Settings::instance().get();
    auto on = [&](int id) { return IsDlgButtonChecked(h, id) == BST_CHECKED; };
    c.macMode = on(IDC_MACMODE);
    c.commandShortcuts = on(IDC_CMDSC);
    c.rightCmdIsWin = on(IDC_RCMDWIN);
    c.macTextNav = on(IDC_TEXTNAV);
    c.optionAsAlt = on(IDC_OPTALT);
    c.fnLanguageSwitch = on(IDC_FNLANG);
    c.fnLayer = on(IDC_FNLAYER);
    c.isoKeyboard = on(IDC_ISO);

    std::vector<uint16_t> langs;
    for (int id : {IDC_LANG1, IDC_LANG2, IDC_LANG3}) {
        uint16_t l = comboLang(h, id);
        if (l && std::find(langs.begin(), langs.end(), l) == langs.end()) langs.push_back(l);
    }
    for (size_t i = 3; i < c.languages.size(); ++i)  // keep extra languages added by hand in settings.ini
        if (std::find(langs.begin(), langs.end(), c.languages[i]) == langs.end()) langs.push_back(c.languages[i]);
    if (langs.size() < 2) {
        MessageBoxW(h, L"Please choose at least two different languages.", L"MacKeyBridge", MB_ICONWARNING);
        return false;
    }
    c.languages = langs;
    int m = (int)SendMessageW(GetDlgItem(h, IDC_METHOD), CB_GETCURSEL, 0, 0);
    c.method = (SwitchMethod)(m < 0 ? 0 : m);

    std::string addr = narrow(dlgText(h, IDC_ADDR));
    in_addr probe{};
    if (inet_pton(AF_INET, addr.c_str(), &probe) != 1) {
        MessageBoxW(h, L"Listen address must be an IPv4 address (0.0.0.0 = all network adapters).", L"MacKeyBridge",
                    MB_ICONWARNING);
        return false;
    }
    int port = _wtoi(dlgText(h, IDC_PORT).c_str());
    if (port < 1 || port > 65535) {
        MessageBoxW(h, L"Port must be between 1 and 65535.", L"MacKeyBridge", MB_ICONWARNING);
        return false;
    }
    std::string secret = narrow(dlgText(h, IDC_SECRET));
    if (secret.size() < 6) {
        MessageBoxW(h, L"The secret must be at least 6 characters. Anyone on your network who knows it can type on "
                       L"this PC.",
                    L"MacKeyBridge", MB_ICONWARNING);
        return false;
    }
    c.bindAddress = addr;
    c.port = port;
    c.secret = secret;
    c.minimizeToTray = on(IDC_MINTRAY);
    c.debug = on(IDC_DEBUG);

    setAutostart(on(IDC_AUTOSTART));
    Settings::instance().set(c);  // saves + applyConfig()
    return true;
}

void openTest();

LRESULT CALLBACK SettingsProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
        case WM_CREATE: {
            S.settings = h;
            S.pages.clear();
            S.ips = localIPv4();
            S.tab = ctl(h, WC_TABCONTROLW, L"", WS_TABSTOP | WS_CLIPSIBLINGS, 8, 8, 524, 380, IDC_TAB);
            const wchar_t* names[] = {L"Keyboard", L"Languages", L"Connection", L"Startup"};
            for (int i = 0; i < 4; ++i) {
                TCITEMW it{};
                it.mask = TCIF_TEXT;
                it.pszText = (LPWSTR)names[i];
                SendMessageW(S.tab, TCM_INSERTITEMW, (WPARAM)i, (LPARAM)&it);
            }
            auto add = [&](int page, HWND c) {
                S.pages.push_back({c, page});
                if (page != 0) ShowWindow(c, SW_HIDE);
                return c;
            };
            auto label = [&](int page, const wchar_t* t, int x, int y, int wd, int ht = 20, int id = 0) {
                return add(page, ctl(h, L"STATIC", t, SS_LEFT, x, y, wd, ht, id));
            };
            auto check = [&](int page, const wchar_t* t, int id, int y) {
                return add(page, ctl(h, L"BUTTON", t, BS_AUTOCHECKBOX | WS_TABSTOP, 24, y, 490, 22, id));
            };
            auto edit = [&](int page, int id, int x, int y, int wd, DWORD extra = 0) {
                return add(page, ctl(h, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP | extra, x, y, wd, 24, id,
                                     WS_EX_CLIENTEDGE));
            };
            auto combo = [&](int page, int id, int x, int y, int wd) {
                return add(page, ctl(h, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, x, y, wd, 200,
                                     id));
            };

            // --- page 0: Keyboard
            check(0, L"Mac keyboard mode (Mac shortcuts become Windows shortcuts)", IDC_MACMODE, 48);
            check(0, L"Command shortcuts: Left Command works as Ctrl (Cmd+C = Ctrl+C)", IDC_CMDSC, 76);
            check(0, L"Right Command = Windows key (off: both Command keys act as Ctrl)", IDC_RCMDWIN, 104);
            check(0, L"Mac text navigation (Cmd+arrows = Home/End, Option+arrows = words)", IDC_TEXTNAV, 132);
            check(0, L"Option = Alt (off: Option = Windows key)", IDC_OPTALT, 160);
            check(0, L"Fn = switch language (tap Fn)", IDC_FNLANG, 188);
            check(0, L"Fn layer: Fn+arrows = Home/End/PgUp/PgDn, Fn+Backspace = Del, Fn+I = Ins", IDC_FNLAYER, 216);
            check(0, L"ISO keyboard (swap the top-left key and the key next to left Shift)", IDC_ISO, 244);
            label(0, L"With 'Command shortcuts' off, Command acts as the Windows key.", 24, 280, 490);

            // --- page 1: Languages
            label(1, L"Language 1:", 24, 56, 110);
            combo(1, IDC_LANG1, 150, 52, 360);
            label(1, L"Language 2:", 24, 92, 110);
            combo(1, IDC_LANG2, 150, 88, 360);
            label(1, L"Language 3 (optional):", 24, 128, 125);
            combo(1, IDC_LANG3, 150, 124, 360);
            label(1, L"Switch method:", 24, 168, 110);
            HWND meth = combo(1, IDC_METHOD, 150, 164, 360);
            const wchar_t* methods[] = {L"Windows API - explicit layout (recommended)", L"Hotkey Win+Space",
                                        L"Hotkey Alt+Shift", L"Hotkey Ctrl+Shift"};
            for (const wchar_t* t : methods) SendMessageW(meth, CB_ADDSTRING, 0, (LPARAM)t);
            label(1, L"", 24, 212, 330, 20, IDC_CURLANG);
            add(1, ctl(h, L"BUTTON", L"Detect current layout", BS_PUSHBUTTON | WS_TABSTOP, 370, 206, 140, 28, IDC_DETECT));
            label(1, L"Fn cycles through the languages above in order. More languages (Uzbek 0x0443, German 0x0407 ...) "
                     L"can be added to 'languages=' in settings.ini. If a program ignores the API method, try a hotkey "
                     L"method.",
                  24, 252, 486, 80);

            // --- page 2: Connection
            label(2, L"Listen address:", 24, 56, 110);
            edit(2, IDC_ADDR, 150, 52, 150);
            label(2, L"Port:", 320, 56, 40);
            edit(2, IDC_PORT, 365, 52, 70);
            label(2, L"Secret:", 24, 92, 110);
            edit(2, IDC_SECRET, 150, 88, 285);
            label(2, L"Status:", 24, 128, 110);
            label(2, L"", 150, 128, 360, 20, IDC_STATUS);
            label(2, L"This PC:", 24, 156, 110);
            label(2, L"", 150, 156, 360, 20, IDC_LOCALIPS);
            label(2, L"On the MacBook run:", 24, 192, 300);
            edit(2, IDC_CMDLINE, 24, 216, 486, ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL);
            SetWindowPos(GetDlgItem(h, IDC_CMDLINE), nullptr, 0, 0, sc(486), sc(70), SWP_NOMOVE | SWP_NOZORDER);
            label(2, L"Keys are not encrypted: use a trusted network (or a VPN such as Tailscale).", 24, 300, 490);

            // --- page 3: Startup
            check(3, L"Start with Windows", IDC_AUTOSTART, 52);
            check(3, L"Start minimized to the tray (no window at startup)", IDC_MINTRAY, 80);
            check(3, L"Debug mode (log every key event)", IDC_DEBUG, 108);
            label(3, L"Log file: %APPDATA%\\MacKeyBridge\\log.txt", 24, 150, 490);

            // --- buttons (always visible)
            ctl(h, L"BUTTON", L"Keyboard Test...", BS_PUSHBUTTON | WS_TABSTOP, 16, 398, 140, 30, IDC_OPENTEST);
            ctl(h, L"BUTTON", L"Save", BS_DEFPUSHBUTTON | WS_TABSTOP, 346, 398, 86, 30, IDC_SAVE);
            ctl(h, L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, 440, 398, 86, 30, IDC_CLOSE);

            loadUi(h);
            return 0;
        }
        case WM_NOTIFY: {
            NMHDR* n = (NMHDR*)l;
            if (n->idFrom == IDC_TAB && n->code == TCN_SELCHANGE) {
                int sel = (int)SendMessageW(S.tab, TCM_GETCURSEL, 0, 0);
                for (auto& p : S.pages) ShowWindow(p.first, p.second == sel ? SW_SHOW : SW_HIDE);
            }
            return 0;
        }
        case WM_COMMAND: {
            const int id = LOWORD(w), code = HIWORD(w);
            if (id == IDC_SAVE && code == BN_CLICKED) {
                if (saveUi(h)) DestroyWindow(h);
            } else if (id == IDC_CLOSE && code == BN_CLICKED) {
                DestroyWindow(h);
            } else if (id == IDC_OPENTEST && code == BN_CLICKED) {
                openTest();
            } else if (id == IDC_DETECT && code == BN_CLICKED) {
                LANGID cur = langOf(currentForeignLayout());
                if (cur) fillLangCombo(GetDlgItem(h, IDC_LANG1), false, cur);
                refreshSettingsStatus();
            } else if ((id == IDC_PORT || id == IDC_SECRET) && code == EN_CHANGE) {
                updateCmdline(h);
            }
            return 0;
        }
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLORBTN: {  // blend with the white tab page
            HDC dc = (HDC)w;
            SetBkColor(dc, RGB(255, 255, 255));
            return (LRESULT)S.white;
        }
        case WM_CLOSE:
            DestroyWindow(h);
            return 0;
        case WM_DESTROY:
            S.settings = nullptr;
            S.tab = nullptr;
            S.pages.clear();
            return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

// ------------------------------------------------------------------ keyboard test window
LRESULT CALLBACK TestProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
        case WM_CREATE: {
            S.test = h;
            const wchar_t* labels[] = {L"Physical key:", L"Detected key:", L"Scan code:", L"Virtual key:",
                                       L"Mapped key:"};
            const int ids[] = {IDC_PHYS, IDC_DET, IDC_SCAN, IDC_VK, IDC_MAPPED};
            for (int i = 0; i < 5; ++i) {
                ctl(h, L"STATIC", labels[i], SS_LEFT, 16, 18 + i * 38, 120, 24, 0);
                HWND v = ctl(h, L"STATIC", L"-", SS_LEFT | SS_ENDELLIPSIS, 140, 14 + i * 38, 364, 30, ids[i]);
                SendMessageW(v, WM_SETFONT, (WPARAM)S.bigFont, TRUE);
            }
            ctl(h, L"BUTTON", L"Test mode: do not send keys to Windows, do not switch the layout",
                BS_AUTOCHECKBOX | WS_TABSTOP, 16, 214, 488, 22, IDC_DRYRUN);
            CheckDlgButton(h, IDC_DRYRUN, BST_CHECKED);
            ctl(h, L"STATIC", L"Press keys on the MacBook (client connected, forwarding ON).", SS_LEFT, 16, 242, 488,
                20, 0);
            ctl(h, L"LISTBOX", L"", WS_VSCROLL | LBS_NOINTEGRALHEIGHT | LBS_NOSEL, 16, 266, 488, 146, IDC_LOG,
                WS_EX_CLIENTEDGE);
            S.kb->setDryRun(true);
            return 0;
        }
        case WM_COMMAND:
            if (LOWORD(w) == IDC_DRYRUN && HIWORD(w) == BN_CLICKED)
                S.kb->setDryRun(IsDlgButtonChecked(h, IDC_DRYRUN) == BST_CHECKED);
            return 0;
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLORBTN:
            SetBkColor((HDC)w, RGB(255, 255, 255));
            return (LRESULT)S.white;
        case WM_CLOSE:
            DestroyWindow(h);
            return 0;
        case WM_DESTROY:
            S.kb->setDryRun(false);
            S.test = nullptr;
            return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

void showTrace(const TraceEvent& t) {
    if (!S.test) return;
    char b[160];
    SetDlgItemTextW(S.test, IDC_PHYS, widen(t.physical).c_str());
    snprintf(b, sizeof b, "Mac keycode %u (0x%02X)  %s%s", (unsigned)t.macCode, (unsigned)t.macCode,
             t.down ? "DOWN" : "UP", t.repeat ? " (repeat)" : "");
    SetDlgItemTextW(S.test, IDC_DET, widen(t.detected.empty() ? std::string(b) : t.detected).c_str());
    if (t.scan >= 0) snprintf(b, sizeof b, "0x%02X%s", (unsigned)t.scan, t.ext ? "  (E0 extended)" : "");
    else snprintf(b, sizeof b, "-");
    SetDlgItemTextW(S.test, IDC_SCAN, widen(b).c_str());
    if (t.vk > 0) snprintf(b, sizeof b, "0x%02X", (unsigned)t.vk);
    else snprintf(b, sizeof b, "-");
    SetDlgItemTextW(S.test, IDC_VK, widen(b).c_str());
    SetDlgItemTextW(S.test, IDC_MAPPED, widen(t.mapped).c_str());

    if (!t.repeat) {
        std::string line = t.physical + (t.down ? "  DOWN  -> " : "  UP    -> ") + t.mapped;
        HWND lb = GetDlgItem(S.test, IDC_LOG);
        int n = (int)SendMessageW(lb, LB_ADDSTRING, 0, (LPARAM)widen(line).c_str());
        if (n >= 300) {
            SendMessageW(lb, LB_DELETESTRING, 0, 0);
            --n;
        }
        SendMessageW(lb, LB_SETTOPINDEX, (WPARAM)n, 0);
    }
}

// ------------------------------------------------------------------ windows
HWND makeWindow(const wchar_t* cls, const wchar_t* title, int w, int h) {
    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT r{0, 0, sc(w), sc(h)};
    AdjustWindowRectEx(&r, style, FALSE, 0);
    const int W = r.right - r.left, H = r.bottom - r.top;
    const int x = (GetSystemMetrics(SM_CXSCREEN) - W) / 2, y = (GetSystemMetrics(SM_CYSCREEN) - H) / 2;
    HWND hw = CreateWindowExW(0, cls, title, style, x, y, W, H, nullptr, nullptr, S.inst, nullptr);
    ShowWindow(hw, SW_SHOW);
    UpdateWindow(hw);
    SetForegroundWindow(hw);
    return hw;
}

void openSettings() {
    if (S.settings) {
        ShowWindow(S.settings, SW_SHOW);
        SetForegroundWindow(S.settings);
        return;
    }
    makeWindow(L"MKBSettings", L"MacKeyBridge - Settings", 540, 440);
}

void openTest() {
    if (S.test) {
        ShowWindow(S.test, SW_SHOW);
        SetForegroundWindow(S.test);
        return;
    }
    makeWindow(L"MKBTest", L"MacKeyBridge - Keyboard Test", 520, 424);
}

void showMenu(HWND hwnd) {
    auto c = Settings::instance().get();
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING | (c->enabled ? MF_CHECKED : 0), ID_ENABLE, L"Enable");
    AppendMenuW(m, MF_STRING | (!c->enabled ? MF_CHECKED : 0), ID_DISABLE, L"Disable");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, ID_SETTINGS, L"Settings...");
    AppendMenuW(m, MF_STRING, ID_TEST, L"Keyboard Test...");
    AppendMenuW(m, MF_STRING | (autostartEnabled() ? MF_CHECKED : 0), ID_AUTOSTART, L"Start with Windows");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, ID_EXIT, L"Exit");
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(hwnd);  // required so the menu closes when clicking elsewhere
    TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd, nullptr);
    PostMessageW(hwnd, WM_NULL, 0, 0);
    DestroyMenu(m);
}

LRESULT CALLBACK MainProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (S.taskbarCreated && m == S.taskbarCreated) {  // Explorer restarted
        S.tray.readd();
        return 0;
    }
    switch (m) {
        case WM_CREATE:
            S.main = h;
            S.tray.create(h, WM_TRAY);
            SetTimer(h, 1, 300, nullptr);
            return 0;
        case WM_TIMER:
            if (w == 1) refreshTray();
            return 0;
        case WM_TRAY:
            if (LOWORD(l) == WM_LBUTTONDBLCLK) openSettings();
            else if (LOWORD(l) == WM_RBUTTONUP || LOWORD(l) == WM_CONTEXTMENU) showMenu(h);
            return 0;
        case WM_STATUS:
            refreshTray();
            return 0;
        case WM_TRACE: {
            std::unique_ptr<TraceEvent> t(reinterpret_cast<TraceEvent*>(l));  // always freed
            showTrace(*t);
            return 0;
        }
        case WM_COMMAND:
            switch (LOWORD(w)) {
                case ID_ENABLE:
                case ID_DISABLE: {
                    Config c = *Settings::instance().get();
                    c.enabled = LOWORD(w) == ID_ENABLE;
                    Settings::instance().set(c);
                    break;
                }
                case ID_SETTINGS: openSettings(); break;
                case ID_TEST: openTest(); break;
                case ID_AUTOSTART: setAutostart(!autostartEnabled()); break;
                case ID_EXIT: DestroyWindow(h); break;
            }
            return 0;
        case kMsgShowSettings:
            openSettings();
            return 0;
        case WM_DESTROY:
            KillTimer(h, 1);
            S.tray.remove();
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

}  // namespace

namespace UI {

int run(HINSTANCE inst, LanguageManager& lang, KeyboardManager& kb, NetworkServer& net, bool showSettings) {
    S.inst = inst;
    S.lang = &lang;
    S.kb = &kb;
    S.net = &net;
    S.dpi = (int)GetDpiForSystem();
    S.white = (HBRUSH)GetStockObject(WHITE_BRUSH);

    NONCLIENTMETRICSW ncm{};
    ncm.cbSize = sizeof ncm;
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof ncm, &ncm, 0);
    S.font = CreateFontIndirectW(&ncm.lfMessageFont);
    LOGFONTW big = ncm.lfMessageFont;
    big.lfWeight = FW_SEMIBOLD;
    big.lfHeight = big.lfHeight * 14 / 10;
    S.bigFont = CreateFontIndirectW(&big);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof wc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpfnWndProc = MainProc;
    wc.lpszClassName = L"MKBMain";
    RegisterClassExW(&wc);
    wc.hbrBackground = S.white;
    wc.lpfnWndProc = SettingsProc;
    wc.lpszClassName = L"MKBSettings";
    RegisterClassExW(&wc);
    wc.lpfnWndProc = TestProc;
    wc.lpszClassName = L"MKBTest";
    RegisterClassExW(&wc);

    S.taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    S.main = CreateWindowExW(0, L"MKBMain", L"MacKeyBridge", WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
    if (!S.main) return 1;

    kb.setTraceSink([](const TraceEvent& t) {
        if (S.test) PostMessageW(S.main, WM_TRACE, 0, (LPARAM) new TraceEvent(t));  // freed in MainProc
    });
    net.onStatus = [] { PostMessageW(S.main, WM_STATUS, 0, 0); };
    Settings::instance().onChanged = [] { applyConfig(); };

    applyConfig();
    if (showSettings) openSettings();

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    net.onStatus = nullptr;
    Settings::instance().onChanged = nullptr;
    kb.setTraceSink(nullptr);
    net.stop();
    DeleteObject(S.font);
    DeleteObject(S.bigFont);
    return (int)msg.wParam;
}

}  // namespace UI


// ==========================================================================
// main.cpp
// ==========================================================================
int WINAPI WinMain(HINSTANCE inst, HINSTANCE, LPSTR, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // Single instance: a second launch just asks the running one to show its settings.
    HANDLE mutex = CreateMutexW(nullptr, FALSE, L"Local\\MacKeyBridge.SingleInstance");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        if (HWND w = FindWindowW(L"MKBMain", nullptr)) PostMessageW(w, kMsgShowSettings, 0, 0);
        if (mutex) CloseHandle(mutex);
        return 0;
    }

    INITCOMMONCONTROLSEX icc{sizeof icc, ICC_TAB_CLASSES | ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        MessageBoxW(nullptr, L"Cannot initialise Winsock.", L"MacKeyBridge", MB_ICONERROR);
        return 1;
    }

    const bool hadSettings = Settings::instance().load();
    Log::init(Settings::instance().dataDir());
    Log::setDebug(Settings::instance().get()->debug);
    LOG_INFO("MacKeyBridge started");

    int rc = 0;
    {
        LanguageManager lang;
        KeyboardManager kb(lang);
        NetworkServer net(kb);
        // First run: show the settings window so the user can see the secret and the connect command.
        const bool showSettings = !hadSettings || !Settings::instance().get()->minimizeToTray;
        rc = UI::run(inst, lang, kb, net, showSettings);
    }

    LOG_INFO("MacKeyBridge exited");
    WSACleanup();
    if (mutex) CloseHandle(mutex);
    return rc;
}
