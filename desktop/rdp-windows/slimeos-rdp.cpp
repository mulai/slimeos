// slimeos-rdp: a Brain's desktop in a window of its own, drawn by Windows'
// Remote Desktop control (mstscax.dll, the engine inside mstsc: hardware
// decode, camera, mic, clipboard). There is no .rdp file, so none of mstsc's
// file warnings ("Unknown remote connection"), and the password goes to the
// control itself, so Windows' rule against saved passwords for NTLM-only
// servers never asks for it again.
//
// The core (desktop/core/launch_windows.go) starts it with key=value lines
// on stdin: addr, name, username, password. Exit code 0: the session ended;
// 2: Windows refused the sign-in; 1: anything else, with the reason as the
// last line on stderr (which goes to desktop.log).

#include <windows.h>
#include <atlbase.h>
#include <atlcom.h>
#include <atlhost.h>

#include <map>
#include <string>

#import "C:\\Windows\\System32\\mstscax.dll" raw_interfaces_only no_smart_pointers
using namespace MSTSCLib;

// Visual styles for the dialogs the control shows itself.
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

CComModule _Module;

static std::map<std::wstring, std::wstring> settings;
static HWND frame, host;
static CComPtr<IMsRdpClient9> rdp;
static bool loggedIn, fitWorks = true;
static int exitCode = 1;

static const UINT WM_ENDED = WM_APP + 1;
static const UINT_PTR fitTimer = 1;

static void say(const wchar_t* fmt, ...) {
    wchar_t buf[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(buf, _TRUNCATE, fmt, ap);
    va_end(ap);
    char out[4096];
    int n = WideCharToMultiByte(CP_UTF8, 0, buf, -1, out, sizeof out - 1, nullptr, nullptr);
    if (n <= 0) return;
    out[n - 1] = '\n';
    DWORD written;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), out, n, &written, nullptr);
}

[[noreturn]] static void fail(const wchar_t* what, HRESULT hr) {
    say(L"rdp: %s failed (0x%08lx)", what, hr);
    ExitProcess(1);
}

#define MUST(x) do { HRESULT hr_ = (x); if (FAILED(hr_)) fail(L#x, hr_); } while (0)
// Settings an older Windows may not have: noted, not fatal.
#define TRY(x) do { HRESULT hr_ = (x); if (FAILED(hr_)) say(L"rdp: %s: 0x%08lx", L#x, hr_); } while (0)

static void readSettings() {
    std::string in;
    char buf[4096];
    DWORD n;
    while (ReadFile(GetStdHandle(STD_INPUT_HANDLE), buf, sizeof buf, &n, nullptr) && n > 0)
        in.append(buf, n);
    std::wstring w(MultiByteToWideChar(CP_UTF8, 0, in.data(), (int)in.size(), nullptr, 0), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, in.data(), (int)in.size(), w.data(), (int)w.size());
    SecureZeroMemory(in.data(), in.size());
    size_t start = 0;
    while (start < w.size()) {
        size_t end = w.find(L'\n', start);
        if (end == std::wstring::npos) end = w.size();
        std::wstring line = w.substr(start, end - start);
        size_t eq = line.find(L'=');
        if (eq != std::wstring::npos) settings[line.substr(0, eq)] = line.substr(eq + 1);
        start = end + 1;
    }
    SecureZeroMemory(w.data(), w.size() * sizeof(wchar_t));
}

static ULONG scaleFor(UINT dpi) {
    ULONG s = dpi * 100 / 96;
    return s < 100 ? 100 : s > 500 ? 500 : s;
}

static ULONG clampSize(LONG v) { return v < 200 ? 200 : v > 8192 ? 8192 : (ULONG)v; }

// fitSession resizes the remote desktop to the window (or the screen in full
// screen) at the monitor's scale, like mstsc's dynamic resolution.
static void fitSession() {
    if (!loggedIn || !fitWorks) return;
    VARIANT_BOOL full = VARIANT_FALSE;
    rdp->get_FullScreen(&full);
    RECT r;
    if (full) {
        MONITORINFO mi{sizeof mi};
        GetMonitorInfoW(MonitorFromWindow(frame, MONITOR_DEFAULTTONEAREST), &mi);
        r = mi.rcMonitor;
    } else {
        GetClientRect(frame, &r);
    }
    ULONG w = clampSize(r.right - r.left) & ~1UL, h = clampSize(r.bottom - r.top);
    UINT dpi = GetDpiForWindow(frame);
    HRESULT hr = rdp->UpdateSessionDisplaySettings(w, h, w * 254 / (dpi * 10), h * 254 / (dpi * 10), 0,
                                                   scaleFor(dpi), 100);
    if (FAILED(hr)) {
        // An older Windows on the Brain: scale the picture instead.
        say(L"rdp: resizing the session: 0x%08lx, scaling the picture instead", hr);
        fitWorks = false;
        CComPtr<IMsTscAdvancedSettings> a;
        if (SUCCEEDED(rdp->get_AdvancedSettings(&a)))
            if (CComQIPtr<IMsRdpClientAdvancedSettings> adv = a) adv->put_SmartSizing(VARIANT_TRUE);
    }
}

static void disconnected(long reason) {
    ExtendedDisconnectReasonCode ext = exDiscReasonNoInfo;
    rdp->get_ExtendedDisconnectReason(&ext);
    CComBSTR text;
    rdp->GetErrorDescription(reason, ext, &text);
    say(L"rdp: disconnected, reason %ld, extended %d: %s", reason, (int)ext, text ? (wchar_t*)text : L"");
    switch (reason) {
    case 1: // closed here
    case 2: // signed out or disconnected on the Brain
    case 3: // ended by the Brain
        exitCode = 0;
        break;
    case 2055: // wrong password
    case 2567: // no such user
        exitCode = 2;
        break;
    default:
        exitCode = 1;
        if (text) say(L"%s", (wchar_t*)text);
    }
    // Not from inside the control's own call.
    PostMessageW(frame, WM_ENDED, 0, 0);
}

static VARIANT* arg(DISPPARAMS* p, UINT i) { return i < p->cArgs ? &p->rgvarg[p->cArgs - 1 - i] : nullptr; }

static long longArg(DISPPARAMS* p, UINT i) {
    VARIANT* v = arg(p, i);
    VARIANT l;
    VariantInit(&l);
    if (!v || FAILED(VariantChangeType(&l, v, 0, VT_I4))) return 0;
    return l.lVal;
}

static void onEvent(const std::wstring& name, DISPPARAMS* p) {
    if (name == L"OnConnected") {
        say(L"rdp: connected");
    } else if (name == L"OnLoginComplete") {
        say(L"rdp: signed in");
        loggedIn = true;
    } else if (name == L"OnDisconnected") {
        disconnected(longArg(p, 0));
    } else if (name == L"OnEnterFullScreenMode" || name == L"OnLeaveFullScreenMode") {
        SetTimer(frame, fitTimer, 300, nullptr);
    } else if (name == L"OnRequestContainerMinimize") {
        ShowWindow(frame, SW_MINIMIZE);
    } else if (name == L"OnConfirmClose") {
        if (VARIANT* v = arg(p, 0); v && (v->vt & VT_BYREF)) *v->pboolVal = VARIANT_TRUE;
    } else if (name == L"OnAutoReconnecting" || name == L"OnAutoReconnecting2") {
        say(L"rdp: connection lost (reason %ld), reconnecting", longArg(p, 0));
    } else if (name == L"OnAutoReconnected") {
        say(L"rdp: reconnected");
    } else if (name == L"OnFatalError" || name == L"OnWarning" || name == L"OnLogonError") {
        say(L"rdp: %s %ld", name.c_str(), longArg(p, 0));
    } else if (name == L"OnAuthenticationWarningDisplayed") {
        say(L"rdp: the control showed an authentication warning");
    }
}

// The control's events (IMsTscAxEvents), looked up by name in its type
// library rather than by number.
class Events : public IDispatch {
    LONG refs = 1;
    std::map<DISPID, std::wstring> names;

public:
    Events() {
        CComPtr<ITypeLib> lib;
        CComPtr<ITypeInfo> info;
        if (FAILED(LoadTypeLibEx(L"mstscax.dll", REGKIND_NONE, &lib)) ||
            FAILED(lib->GetTypeInfoOfGuid(__uuidof(IMsTscAxEvents), &info)))
            fail(L"reading the control's events", E_FAIL);
        TYPEATTR* ta;
        MUST(info->GetTypeAttr(&ta));
        for (UINT i = 0; i < ta->cFuncs; i++) {
            FUNCDESC* fd;
            if (FAILED(info->GetFuncDesc(i, &fd))) continue;
            CComBSTR n;
            if (SUCCEEDED(info->GetDocumentation(fd->memid, &n, nullptr, nullptr, nullptr)))
                names[fd->memid] = (wchar_t*)n;
            info->ReleaseFuncDesc(fd);
        }
        info->ReleaseTypeAttr(ta);
    }
    STDMETHODIMP QueryInterface(REFIID iid, void** p) override {
        if (iid == IID_IUnknown || iid == IID_IDispatch || iid == __uuidof(IMsTscAxEvents)) {
            *p = this;
            AddRef();
            return S_OK;
        }
        *p = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs); }
    STDMETHODIMP_(ULONG) Release() override { return InterlockedDecrement(&refs); } // static lifetime
    STDMETHODIMP GetTypeInfoCount(UINT* n) override { *n = 0; return S_OK; }
    STDMETHODIMP GetTypeInfo(UINT, LCID, ITypeInfo**) override { return E_NOTIMPL; }
    STDMETHODIMP GetIDsOfNames(REFIID, LPOLESTR*, UINT, LCID, DISPID*) override { return E_NOTIMPL; }
    STDMETHODIMP Invoke(DISPID id, REFIID, LCID, WORD, DISPPARAMS* p, VARIANT*, EXCEPINFO*, UINT*) override {
        auto it = names.find(id);
        if (it != names.end()) onEvent(it->second, p);
        return S_OK;
    }
};

static void configure(const std::wstring& title) {
    std::wstring addr = settings[L"addr"], server = addr;
    long port = 3389;
    if (size_t c = addr.rfind(L':'); c != std::wstring::npos) {
        server = addr.substr(0, c);
        port = wcstol(addr.c_str() + c + 1, nullptr, 10);
    }
    const std::wstring &name = settings[L"name"], &user = settings[L"username"], &password = settings[L"password"];

    MUST(rdp->put_Server(CComBSTR(server.c_str())));
    if (!user.empty()) MUST(rdp->put_UserName(CComBSTR(user.c_str())));
    MUST(rdp->put_ColorDepth(32));
    TRY(rdp->put_ConnectingText(CComBSTR((L"Connecting to " + name + L"…").c_str())));
    TRY(rdp->put_FullScreenTitle(CComBSTR(title.c_str())));

    CComPtr<IMsTscAdvancedSettings> a;
    MUST(rdp->get_AdvancedSettings(&a));
    CComQIPtr<IMsRdpClientAdvancedSettings8> adv = a;
    if (!adv) fail(L"IMsRdpClientAdvancedSettings8", E_NOINTERFACE);
    MUST(adv->put_RDPPort(port));
    // The tunnel already proves which Brain this is; its certificate is
    // self-signed and names the Brain, not the loopback address.
    MUST(adv->put_AuthenticationLevel(0));
    TRY(adv->put_EnableAutoReconnect(VARIANT_TRUE));
    TRY(adv->put_RedirectClipboard(VARIANT_TRUE));
    TRY(adv->put_RedirectPrinters(VARIANT_FALSE));
    TRY(adv->put_RedirectSmartCards(VARIANT_FALSE));
    TRY(adv->put_AudioCaptureRedirectionMode(VARIANT_TRUE));
    TRY(adv->put_NetworkConnectionType(7)); // detect automatically
    TRY(adv->put_BandwidthDetection(VARIANT_TRUE));
    TRY(adv->put_DisplayConnectionBar(VARIANT_TRUE));
    TRY(adv->put_SmartSizing(VARIANT_FALSE));

    CComQIPtr<IMsRdpClientNonScriptable5> ns = rdp;
    if (!ns) fail(L"IMsRdpClientNonScriptable5", E_NOINTERFACE);
    if (!password.empty()) MUST(ns->put_ClearTextPassword(CComBSTR(password.c_str())));
    MUST(ns->put_EnableCredSspSupport(VARIANT_TRUE));
    TRY(ns->put_NegotiateSecurityLayer(VARIANT_TRUE));
    // With a password from Slime OS, a wrong one comes back to the app,
    // which asks again; without one, Windows' own sign-in box.
    TRY(ns->put_PromptForCredentials(VARIANT_FALSE));
    TRY(ns->put_AllowPromptingForCredentials(password.empty() ? VARIANT_TRUE : VARIANT_FALSE));
    TRY(ns->put_ShowRedirectionWarningDialog(VARIANT_FALSE));
    TRY(ns->put_WarnAboutSendingCredentials(VARIANT_FALSE));
    TRY(ns->put_WarnAboutClipboardRedirection(VARIANT_FALSE));
    TRY(ns->put_ConnectionBarText(CComBSTR(name.c_str())));

    // Every camera, as mstsc's camerastoredirect:s:*.
    if (CComQIPtr<IMsRdpClientNonScriptable7> ns7 = rdp) {
        CComPtr<IMsRdpCameraRedirConfigCollection> cams;
        if (SUCCEEDED(ns7->get_CameraRedirConfigCollection(&cams))) {
            TRY(cams->Rescan());
            TRY(cams->put_RedirectByDefault(VARIANT_TRUE));
            ULONG n = 0;
            cams->get_Count(&n);
            for (ULONG i = 0; i < n; i++) {
                CComPtr<IMsRdpCameraRedirConfig> cam;
                if (SUCCEEDED(cams->get_ByIndex(i, &cam))) TRY(cam->put_Redirected(VARIANT_TRUE));
            }
            say(L"rdp: %lu camera(s)", n);
        }
    }

    // Full screen on the monitor this window is on, at its scale, like mstsc.
    MONITORINFO mi{sizeof mi};
    GetMonitorInfoW(MonitorFromWindow(frame, MONITOR_DEFAULTTONEAREST), &mi);
    MUST(rdp->put_DesktopWidth(clampSize(mi.rcMonitor.right - mi.rcMonitor.left) & ~1UL));
    MUST(rdp->put_DesktopHeight(clampSize(mi.rcMonitor.bottom - mi.rcMonitor.top)));
    if (CComQIPtr<IMsRdpExtendedSettings> ext = rdp) {
        CComVariant scale((ULONG)scaleFor(GetDpiForWindow(frame))), device((ULONG)100);
        TRY(ext->put_Property(CComBSTR(L"DesktopScaleFactor"), &scale));
        TRY(ext->put_Property(CComBSTR(L"DeviceScaleFactor"), &device));
    }
    MUST(rdp->put_FullScreen(VARIANT_TRUE));
}

static LRESULT CALLBACK frameProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_SIZE:
        if (host) MoveWindow(host, 0, 0, LOWORD(lp), HIWORD(lp), TRUE);
        if (wp != SIZE_MINIMIZED) SetTimer(hwnd, fitTimer, 400, nullptr);
        return 0;
    case WM_TIMER:
        if (wp == fitTimer) {
            KillTimer(hwnd, fitTimer);
            fitSession();
        }
        return 0;
    case WM_SYSCOMMAND:
        // Maximize means full screen, as in mstsc.
        if ((wp & 0xFFF0) == SC_MAXIMIZE && rdp && loggedIn) {
            rdp->put_FullScreen(VARIANT_TRUE);
            return 0;
        }
        break;
    case WM_DPICHANGED: {
        const RECT* r = (const RECT*)lp;
        SetWindowPos(hwnd, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_SETFOCUS:
        if (host) SetFocus(host);
        return 0;
    case WM_CLOSE: {
        // Disconnect, not sign out: the Brain keeps the Windows session.
        short state = 0;
        if (rdp && SUCCEEDED(rdp->get_Connected(&state)) && state != 0 && SUCCEEDED(rdp->Disconnect())) return 0;
        exitCode = 0;
        DestroyWindow(hwnd);
        return 0;
    }
    case WM_ENDED:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    readSettings();
    MUST(OleInitialize(nullptr));
    _Module.Init(nullptr, inst);
    AtlAxWinInit();

    std::wstring title = settings[L"name"].empty() ? L"Slime OS" : settings[L"name"] + L" – Slime OS";
    WNDCLASSEXW wc{sizeof wc};
    wc.lpfnWndProc = frameProc;
    wc.hInstance = inst;
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = CreateSolidBrush(RGB(5, 8, 11));
    wc.lpszClassName = L"SlimeOSRemoteDesktop";
    RegisterClassExW(&wc);

    // A window at most of the work area of the monitor under the mouse, for
    // when the session leaves full screen.
    POINT cursor;
    GetCursorPos(&cursor);
    MONITORINFO mi{sizeof mi};
    GetMonitorInfoW(MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY), &mi);
    RECT wa = mi.rcWork;
    int w = (wa.right - wa.left) * 4 / 5, h = (wa.bottom - wa.top) * 4 / 5;
    frame = CreateWindowExW(0, wc.lpszClassName, title.c_str(), WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
                            wa.left + (wa.right - wa.left - w) / 2, wa.top + (wa.bottom - wa.top - h) / 2, w, h,
                            nullptr, nullptr, inst, nullptr);
    if (!frame) fail(L"CreateWindow", HRESULT_FROM_WIN32(GetLastError()));
    RECT client;
    GetClientRect(frame, &client);
    host = CreateWindowExW(0, L"AtlAxWin", nullptr, WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, 0, 0, client.right,
                           client.bottom, frame, nullptr, inst, nullptr);
    if (!host) fail(L"CreateWindow(AtlAxWin)", HRESULT_FROM_WIN32(GetLastError()));

    CComPtr<IUnknown> control;
    MUST(CoCreateInstance(__uuidof(MsRdpClient9NotSafeForScripting), nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(&control)));
    MUST(AtlAxAttachControl(control, host, nullptr));
    MUST(control->QueryInterface(&rdp));

    static Events events;
    DWORD cookie = 0;
    CComQIPtr<IConnectionPointContainer> cpc = rdp;
    CComPtr<IConnectionPoint> cp;
    if (!cpc || FAILED(cpc->FindConnectionPoint(__uuidof(IMsTscAxEvents), &cp)) || FAILED(cp->Advise(&events, &cookie)))
        fail(L"listening to the control", E_FAIL);

    configure(title);
    ShowWindow(frame, SW_SHOWNORMAL);
    MUST(rdp->Connect());
    for (auto& [key, value] : settings) SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t));
    settings.clear();

    MSG m;
    while (GetMessageW(&m, nullptr, 0, 0) > 0) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    cp->Unadvise(cookie);
    cp.Release();
    cpc.Release();
    rdp.Release();
    control.Release();
    OleUninitialize();
    return exitCode;
}
