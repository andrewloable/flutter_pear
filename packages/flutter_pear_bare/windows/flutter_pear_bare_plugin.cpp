#include "flutter_pear_bare_plugin.h"

// This must be included before any other Windows headers (per Flutter's own
// plugin template convention -- windows.h has ordering-sensitive macros).
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_message_codec.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace flutter_pear_bare {

namespace {

// The asset subpath already includes the owning package's directory
// (Windows' flat data\flutter_assets\packages\<pkg>\ layout, confirmed
// against a real build) -- no separate "fromPackage" lookup call exists on
// this platform the way iOS/macOS's FlutterDartProject API has one.
const wchar_t *kBundleAssetSubpath =
    L"packages\\flutter_pear\\assets\\desktop\\win32-x64\\pear-end.bundle";

// Custom relay-window messages (see "static, process-lifetime state" below).
constexpr UINT kMsgWorkletData = WM_APP + 1;
constexpr UINT kMsgWorkletExit = WM_APP + 2;

// A heap-allocated payload posted from the reader/waiter threads to the
// relay window; the window procedure takes ownership and deletes it.
struct WorkletDataPayload {
  std::vector<uint8_t> bytes;
};
struct WorkletExitPayload {
  std::wstring reason;
};

// Real UTF-8 <-> UTF-16 conversion (CP_UTF8), not a naive iterator-based
// truncation/widening -- Dart strings are UTF-8 on the wire, Windows paths
// are natively UTF-16, and MSVC's strict warnings-as-errors setting
// correctly rejects a bare wchar_t<->char narrowing construction as the
// silent data-loss bug it would be for any non-ASCII path or reason text.
std::wstring Utf8ToWide(const std::string &utf8) {
  if (utf8.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                 static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), size);
  return wide;
}

std::string WideToUtf8(const std::wstring &wide) {
  if (wide.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                 static_cast<int>(wide.size()), nullptr, 0,
                                 nullptr, nullptr);
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      utf8.data(), size, nullptr, nullptr);
  return utf8;
}

}  // namespace

// Worklet lifecycle (mirrors WorkletState in bare_worklet.dart). This
// comment block is duplicated VERBATIM in FlutterPearBarePlugin.kt/.swift,
// the Linux host (linux/flutter_pear_bare_plugin.cc), and this file
// (eng-4A) -- edit all together, never just one, or the hosts silently
// drift apart.
//
//   stopped --start() (fresh boot)--> running --suspend()--> suspended
//      ^                                 |  ^                    |
//      |                                 |  |--------resume()----|
//      |--------------terminate()--------|
//      |
//      |--onWorkletExit (crash backstop, from EITHER running or suspended)
//
// Windows-specific (flutter_pear-pfp, E-D2b): same embedding shape as
// macOS/Linux -- no BareKit equivalent exists for desktop, so this host
// spawns the real `bare` runtime as a SUBPROCESS and relays raw binary IPC
// over its stdin/stdout. `suspend`/`resume` are deliberate no-ops here, same
// rationale as macOS/Linux: desktop has no OS-imposed background execution
// limit, so there is nothing to pause.
//
// Unlike POSIX (where `bare` is a single shebang-executed process, so a
// single kill() tears down the real bare-runtime binary directly), the npm
// global install of `bare` on Windows is a THREE-PROCESS chain: cmd.exe (to
// get PATHEXT/shim resolution for bare.cmd, exactly as a real `bare <args>`
// typed at a prompt would resolve) -> node.exe (bare.cmd's own shim invokes
// `node "...\bin\bare" %*`) -> the real native bare-runtime binary, spawned
// by bare's own `require('bare-runtime/spawn')` with `stdio: 'inherit'`
// (confirmed by reading the installed bin/bare script on a real Windows
// box before writing this). Killing only the top-level cmd.exe handle would
// orphan node.exe and its bare-runtime grandchild -- so this host assigns
// the whole tree to a Job Object (CREATE_SUSPENDED + AssignProcessToJobObject
// + ResumeThread, avoiding the race where cmd.exe could spawn its child
// before the assignment lands) and kills the JOB, not just the top process.
//
// Reattach-across-hot-restart uses the SAME static-state-survives-a-
// plugin-reinit pattern the other hosts use -- but unlike GTK/Cocoa's async
// I/O (whose completion callbacks always land back on the platform/UI
// thread automatically), Win32 pipe reads here are blocking, so a
// dedicated reader thread does the blocking ReadFile loop and hands
// completed reads to the UI thread via PostMessage to a hidden,
// message-only relay window -- the *only* place this host actually calls
// into a flutter::BasicMessageChannel/MethodChannel, since
// FlutterDesktopMessengerSend's own docs require either the platform
// thread or an explicit Lock/Unlock this client-wrapper layer doesn't
// expose a handle for.
struct _WorkletState {};  // (documentation anchor only; see globals below)

// Static, process-lifetime state (survives a hot-restart's plugin reinit --
// mirrors the other hosts' own static/class-level state). g_current_plugin
// is a weak (non-owning) pointer to whichever FlutterPearBarePlugin
// instance is currently attached -- unlike Linux/macOS, where every async
// I/O callback captures its own `self` at call time, this host's reader/
// waiter threads run continuously for the worklet's whole lifetime (they
// don't get re-armed per Dart call), so the relay window needs a way to
// reach whichever plugin instance is CURRENT when a message actually
// arrives, which may be a different instance than the one active when the
// thread was started (e.g. after a hot restart's reattach).
namespace {
HANDLE g_worklet_process = nullptr;  // handle to the top-level cmd.exe
HANDLE g_worklet_job = nullptr;      // Job Object; killing it kills the tree
HANDLE g_worklet_stdin_write = nullptr;
HANDLE g_worklet_stdout_read = nullptr;
int g_worklet_generation = 0;
HWND g_relay_window = nullptr;
bool g_wndclass_registered = false;
bool g_shutdown_hook_registered = false;
FlutterPearBarePlugin *g_current_plugin = nullptr;

const wchar_t *kRelayWindowClassName = L"FlutterPearBareRelayWindow";

void TeardownWorkletState() {
  if (g_worklet_stdin_write != nullptr) {
    CloseHandle(g_worklet_stdin_write);
    g_worklet_stdin_write = nullptr;
  }
  if (g_worklet_stdout_read != nullptr) {
    // Closed BEFORE the process/job below so the reader thread's blocking
    // ReadFile unblocks with an error and exits quietly, whether this is an
    // intentional terminate() or cleanup after an already-detected crash --
    // same ordering rationale as every other host's terminateWorklet().
    CloseHandle(g_worklet_stdout_read);
    g_worklet_stdout_read = nullptr;
  }
  if (g_worklet_job != nullptr) {
    // Kills cmd.exe, node.exe, and the real bare-runtime grandchild in one
    // call -- see the class-level comment above for why a plain
    // TerminateProcess on just the top handle would orphan the rest.
    TerminateJobObject(g_worklet_job, 0);
    CloseHandle(g_worklet_job);
    g_worklet_job = nullptr;
  }
  if (g_worklet_process != nullptr) {
    CloseHandle(g_worklet_process);
    g_worklet_process = nullptr;
  }
}

// Runs on a background thread for the worklet's entire lifetime (started
// once per fresh boot, NOT re-armed on reattach -- unlike the async-I/O
// hosts, there is nothing to re-arm since this loop never stops on its
// own until the pipe closes). Every posted message is tagged with the
// generation active when the READ was issued, so the relay window can
// discard stale messages from an already-torn-down generation.
void ReaderThreadMain(HANDLE stdout_read, int generation) {
  std::vector<uint8_t> buffer(65536);
  for (;;) {
    DWORD bytes_read = 0;
    BOOL ok = ReadFile(stdout_read, buffer.data(),
                        static_cast<DWORD>(buffer.size()), &bytes_read,
                        nullptr);
    if (!ok || bytes_read == 0) {
      // EOF or a read error -- the pipe closed, whether via an intentional
      // terminate() (which closes this handle first) or the process dying
      // on its own (the waiter thread below reports that case).
      return;
    }
    auto *payload = new WorkletDataPayload();
    payload->bytes.assign(buffer.begin(), buffer.begin() + bytes_read);
    if (g_relay_window == nullptr ||
        !PostMessageW(g_relay_window, kMsgWorkletData,
                     static_cast<WPARAM>(generation),
                     reinterpret_cast<LPARAM>(payload))) {
      delete payload;
    }
  }
}

// Runs on a background thread for the worklet's entire lifetime -- the
// E2.6 backstop, mirrored from every other host's own wait-for-exit
// mechanism (GSubprocess's wait_async on Linux, Process.exitCode on macOS).
void WaiterThreadMain(HANDLE process, int generation) {
  WaitForSingleObject(process, INFINITE);
  DWORD exit_code = 0;
  GetExitCodeProcess(process, &exit_code);
  auto *payload = new WorkletExitPayload();
  std::wostringstream reason;
  reason << L"bare subprocess exited (status " << exit_code << L")";
  payload->reason = reason.str();
  if (g_relay_window == nullptr ||
      !PostMessageW(g_relay_window, kMsgWorkletExit,
                   static_cast<WPARAM>(generation),
                   reinterpret_cast<LPARAM>(payload))) {
    delete payload;
  }
}

// Tears down this generation's static state (so the next start_worklet()
// boots fresh instead of "reattaching" to a subprocess that's actually
// gone) and notifies Dart via the control channel with `reason`. Mirrors
// every other host's identically-named method. Runs on the UI thread (the
// relay window's own thread), so calling into control_channel() here is
// safe without any additional marshaling.
void ReportUnexpectedExit(const std::wstring &reason_w, int generation) {
  if (generation != g_worklet_generation || g_worklet_process == nullptr) {
    return;  // already torn down by terminate(), or a stale generation
  }
  TeardownWorkletState();
  if (g_current_plugin == nullptr || !g_current_plugin->attached) return;
  std::string reason = WideToUtf8(reason_w);
  flutter::EncodableMap args;
  args[flutter::EncodableValue("reason")] = flutter::EncodableValue(reason);
  args[flutter::EncodableValue("generationId")] =
      flutter::EncodableValue(static_cast<int32_t>(generation));
  g_current_plugin->control_channel()->InvokeMethod(
      "onWorkletExit",
      std::make_unique<flutter::EncodableValue>(args));
}

// The relay window's own procedure -- the ONLY place this host calls
// BasicMessageChannel::Send/MethodChannel::InvokeMethod from a background
// thread's data, since PostMessageW guarantees this runs on the thread
// that created the window (the UI/platform thread, since the window is
// created from RegisterWithRegistrar).
LRESULT CALLBACK RelayWndProc(HWND hwnd, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  if (message == kMsgWorkletData) {
    std::unique_ptr<WorkletDataPayload> payload(
        reinterpret_cast<WorkletDataPayload *>(lparam));
    int generation = static_cast<int>(wparam);
    if (generation == g_worklet_generation && g_current_plugin != nullptr &&
        g_current_plugin->attached) {
      g_current_plugin->ipc_channel()->Send(
          flutter::EncodableValue(payload->bytes));
    }
    return 0;
  }
  if (message == kMsgWorkletExit) {
    std::unique_ptr<WorkletExitPayload> payload(
        reinterpret_cast<WorkletExitPayload *>(lparam));
    ReportUnexpectedExit(payload->reason, static_cast<int>(wparam));
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// Standard trick for a DLL to get its OWN module handle (as opposed to the
// host .exe's) without a DllMain -- needed so the relay window class is
// registered against the module that actually owns RelayWndProc.
HMODULE GetOwnModuleHandle() {
  HMODULE module = nullptr;
  GetModuleHandleExW(
      GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
          GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      reinterpret_cast<LPCWSTR>(&RelayWndProc), &module);
  return module;
}

void EnsureRelayWindow() {
  if (g_relay_window != nullptr) return;
  HMODULE module = GetOwnModuleHandle();
  if (!g_wndclass_registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = RelayWndProc;
    wc.hInstance = module;
    wc.lpszClassName = kRelayWindowClassName;
    RegisterClassExW(&wc);
    g_wndclass_registered = true;
  }
  // HWND_MESSAGE: a message-only window -- no visual surface, never shown,
  // just an isolated message-queue endpoint tied to this (the UI) thread.
  g_relay_window =
      CreateWindowExW(0, kRelayWindowClassName, L"", 0, 0, 0, 0, 0,
                      HWND_MESSAGE, nullptr, module, nullptr);
}

// Kills the worklet's whole process tree on a NORMAL app quit (window
// close) -- flutter_pear-pfp, mirrors the macOS/Linux hosts' own shutdown
// hooks. Registered once (guarded by g_shutdown_hook_registered) against
// the app's real top-level window; WM_DESTROY fires once the window is
// already committed to closing, so this never blocks/vetoes a close the
// way hooking WM_CLOSE could. Always returns std::nullopt so this delegate
// never claims to have "handled" the message -- it only observes.
std::optional<LRESULT> OnTopLevelWindowProc(HWND hwnd, UINT message,
                                            WPARAM wparam, LPARAM lparam) {
  if (message == WM_DESTROY && g_worklet_process != nullptr) {
    TeardownWorkletState();
  }
  return std::nullopt;
}

// Quotes a single argument per the Windows command-line quoting rules (the
// documented inverse of CommandLineToArgvW's own parsing algorithm) -- both
// bundle_path and storage_dir are real filesystem paths that may contain
// spaces (confirmed necessary: a real account on this project's own test
// box has a display name with a space in it), so this can't be skipped.
std::wstring QuoteArg(const std::wstring &arg) {
  if (!arg.empty() && arg.find_first_of(L" \t\"") == std::wstring::npos) {
    return arg;
  }
  std::wstring result = L"\"";
  for (auto it = arg.begin();; ++it) {
    size_t backslashes = 0;
    while (it != arg.end() && *it == L'\\') {
      ++it;
      ++backslashes;
    }
    if (it == arg.end()) {
      result.append(backslashes * 2, L'\\');
      break;
    } else if (*it == L'"') {
      result.append(backslashes * 2 + 1, L'\\');
      result.push_back(L'"');
    } else {
      result.append(backslashes, L'\\');
      result.push_back(*it);
    }
  }
  result.push_back(L'"');
  return result;
}

// Resolves the bundled pear-end.bundle's absolute path -- Windows' Flutter
// asset bundle is a flat, predictable layout (confirmed against a real
// build): <bundle_root>\data\flutter_assets\<asset_subpath>, with the
// executable itself living directly at <bundle_root>\<exe_name>.exe.
bool ResolveBundlePath(std::wstring *out_path) {
  wchar_t exe_path[MAX_PATH];
  DWORD len = GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (len == 0 || len == MAX_PATH) return false;
  std::wstring path(exe_path, len);
  size_t last_slash = path.find_last_of(L'\\');
  if (last_slash == std::wstring::npos) return false;
  *out_path = path.substr(0, last_slash) + L"\\data\\flutter_assets\\" +
             kBundleAssetSubpath;
  return true;
}

// %LOCALAPPDATA% -- the Windows analogue of macOS's Application Support /
// Linux's XDG data dir / Android's private filesDir (Eng2 decision 35:
// never a cloud-synced location). Deliberately NOT %APPDATA% (Roaming),
// which Windows explicitly designs to roam across machines in domain
// environments -- exactly the "a sync/restore forks a Hypercore writer key
// onto a second device" failure mode this decision exists to avoid.
bool ResolveStorageDir(std::wstring *out_dir) {
  wchar_t buf[MAX_PATH];
  DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) return false;
  std::wstring dir = std::wstring(buf, len) + L"\\flutter_pear";
  if (!CreateDirectoryW(dir.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }
  *out_dir = dir;
  return true;
}

// Returns true if this call reattached to an already-running worklet,
// false if it booted a fresh one. `error` is set (non-empty) on failure.
bool StartWorklet(const std::wstring &bundle_path_arg, std::wstring *error) {
  if (g_worklet_process != nullptr) {
    // Hot-restart safe: Dart state resets but the subprocess (and its
    // reader/waiter threads) keep running -- g_current_plugin is updated by
    // the caller before this returns, so the next posted message routes to
    // the NEW plugin instance. Nothing else needs re-arming (unlike the
    // async-I/O hosts): the reader thread never stopped.
    return true;
  }

  std::wstring bundle_path = bundle_path_arg;
  if (bundle_path.empty()) {
    if (!ResolveBundlePath(&bundle_path)) {
      *error = L"could not resolve this executable's own path";
      return false;
    }
    if (GetFileAttributesW(bundle_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
      *error = L"could not resolve the bundled " +
               std::wstring(kBundleAssetSubpath) + L" asset";
      return false;
    }
  }

  std::wstring storage_dir;
  if (!ResolveStorageDir(&storage_dir)) {
    *error = L"could not create the storage directory under %LOCALAPPDATA%";
    return false;
  }

  // Piped stdio for the child (cmd.exe, and everything it spawns -- see the
  // class-level comment for why this is a 3-process chain on Windows). The
  // child-side handles must be inheritable; the parent-side ones must NOT
  // be, so they aren't leaked into unrelated future child processes.
  SECURITY_ATTRIBUTES sa = {};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;
  HANDLE child_stdin_read = nullptr, parent_stdin_write = nullptr;
  HANDLE parent_stdout_read = nullptr, child_stdout_write = nullptr;
  if (!CreatePipe(&child_stdin_read, &parent_stdin_write, &sa, 0) ||
      !CreatePipe(&parent_stdout_read, &child_stdout_write, &sa, 0)) {
    *error = L"could not create stdio pipes for the worklet subprocess";
    return false;
  }
  SetHandleInformation(parent_stdin_write, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(parent_stdout_read, HANDLE_FLAG_INHERIT, 0);

  // `cmd.exe /c bare ...` (not a direct CreateProcess of a resolved `bare`
  // path): letting cmd.exe do PATHEXT resolution is the SAME code path a
  // real `bare <args>` typed at a prompt takes, so it correctly finds
  // whatever shape a given machine's npm install produced (bare.cmd,
  // bare.ps1, or a future native bare.exe) without this host having to
  // hardcode npm's own internal package layout. %* inside bare.cmd
  // reproduces each argument's ORIGINAL quoting as received (documented
  // batch-file behavior), so the explicit quoting below survives the whole
  // chain intact even for paths containing spaces.
  std::wstring cmdline = L"cmd.exe /c bare " + QuoteArg(bundle_path) + L" " +
                        QuoteArg(storage_dir);
  std::vector<wchar_t> cmdline_buf(cmdline.begin(), cmdline.end());
  cmdline_buf.push_back(L'\0');

  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdInput = child_stdin_read;
  startup_info.hStdOutput = child_stdout_write;
  // Inherit real stderr (not piped) -- pear-end's own uncaughtException/
  // unhandledRejection handler already reports crashes over the IPC data
  // channel itself; stderr is a debugging convenience, not a signal this
  // host parses (matches every other desktop host).
  startup_info.hStdError = GetStdHandle(STD_ERROR_HANDLE);

  PROCESS_INFORMATION process_info = {};
  // CREATE_SUSPENDED: so this process can be assigned to the Job Object
  // below BEFORE it (or anything it spawns) starts running -- otherwise
  // there's a real race where cmd.exe could spawn node.exe before the job
  // assignment lands, and that grandchild would escape the job.
  // CREATE_NO_WINDOW: this is a background worklet, no console should ever
  // flash on screen.
  BOOL created = CreateProcessW(
      nullptr, cmdline_buf.data(), nullptr, nullptr, /*bInheritHandles=*/TRUE,
      CREATE_SUSPENDED | CREATE_NO_WINDOW, nullptr, storage_dir.c_str(),
      &startup_info, &process_info);
  CloseHandle(child_stdin_read);
  CloseHandle(child_stdout_write);
  if (!created) {
    CloseHandle(parent_stdin_write);
    CloseHandle(parent_stdout_read);
    *error = L"the `bare` runtime was not found, or failed to start";
    return false;
  }

  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (job != nullptr) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                            sizeof(limits));
    AssignProcessToJobObject(job, process_info.hProcess);
  }
  ResumeThread(process_info.hThread);
  CloseHandle(process_info.hThread);

  int active_generation = g_worklet_generation + 1;
  g_worklet_process = process_info.hProcess;
  g_worklet_job = job;
  g_worklet_stdin_write = parent_stdin_write;
  g_worklet_stdout_read = parent_stdout_read;
  g_worklet_generation = active_generation;

  EnsureRelayWindow();
  std::thread(ReaderThreadMain, g_worklet_stdout_read, active_generation)
      .detach();
  std::thread(WaiterThreadMain, g_worklet_process, active_generation)
      .detach();
  return false;
}

}  // namespace

// static
void FlutterPearBarePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto control_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_pear_bare/control",
          &flutter::StandardMethodCodec::GetInstance());
  auto ipc_channel = std::make_unique<
      flutter::BasicMessageChannel<flutter::EncodableValue>>(
      registrar->messenger(), "flutter_pear_bare/ipc",
      &flutter::StandardMessageCodec::GetInstance());

  auto plugin = std::make_unique<FlutterPearBarePlugin>(
      std::move(control_channel), std::move(ipc_channel));
  g_current_plugin = plugin.get();

  auto *control_channel_ptr = plugin->control_channel();
  control_channel_ptr->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  if (!g_shutdown_hook_registered) {
    registrar->RegisterTopLevelWindowProcDelegate(OnTopLevelWindowProc);
    g_shutdown_hook_registered = true;
  }

  registrar->AddPlugin(std::move(plugin));
}

FlutterPearBarePlugin::FlutterPearBarePlugin(
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
        control_channel,
    std::unique_ptr<flutter::BasicMessageChannel<flutter::EncodableValue>>
        ipc_channel)
    : control_channel_(std::move(control_channel)),
      ipc_channel_(std::move(ipc_channel)) {
  ipc_channel_->SetMessageHandler(
      [this](const flutter::EncodableValue &message, const auto &reply) {
        if (const auto *bytes =
                std::get_if<std::vector<uint8_t>>(&message)) {
          if (g_worklet_stdin_write != nullptr) {
            DWORD written = 0;
            WriteFile(g_worklet_stdin_write, bytes->data(),
                     static_cast<DWORD>(bytes->size()), &written, nullptr);
          }
        }
        reply(flutter::EncodableValue());
      });
}

FlutterPearBarePlugin::~FlutterPearBarePlugin() {
  attached = false;
  if (g_current_plugin == this) g_current_plugin = nullptr;
}

void FlutterPearBarePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string &method = method_call.method_name();

  if (method == "start") {
    std::wstring bundle_path_arg;
    if (const auto *args =
            std::get_if<flutter::EncodableMap>(method_call.arguments())) {
      auto it = args->find(flutter::EncodableValue("bundlePath"));
      if (it != args->end()) {
        if (const auto *s = std::get_if<std::string>(&it->second)) {
          bundle_path_arg = Utf8ToWide(*s);
        }
      }
    }
    g_current_plugin = this;
    std::wstring error;
    bool reattached = StartWorklet(bundle_path_arg, &error);
    if (!error.empty()) {
      result->Error("worklet_start_failed", WideToUtf8(error));
    } else {
      flutter::EncodableMap response;
      response[flutter::EncodableValue("reattached")] =
          flutter::EncodableValue(reattached);
      response[flutter::EncodableValue("generationId")] =
          flutter::EncodableValue(static_cast<int32_t>(g_worklet_generation));
      result->Success(flutter::EncodableValue(response));
    }
  } else if (method == "suspend" || method == "resume") {
    // Deliberate no-op (flutter_pear-pfp), same rationale as macOS/Linux:
    // desktop has no OS-imposed background execution limit, so there is
    // nothing to pause -- ack rather than not-implemented so Dart's own
    // no-op-safe suspend()/resume() doesn't throw calling these.
    result->Success();
  } else if (method == "terminate") {
    TeardownWorkletState();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace flutter_pear_bare
