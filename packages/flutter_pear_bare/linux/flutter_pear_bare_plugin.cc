#include "include/flutter_pear_bare/flutter_pear_bare_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <glib.h>
#include <glib/gstdio.h>

#include <cstring>
#include <string>

#define FLUTTER_PEAR_BARE_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_pear_bare_plugin_get_type(), \
                               FlutterPearBarePlugin))

// Subpath (within `flutter_pear`'s Flutter assets) of the bundled pear-end
// -- Linux uses the DESKTOP bundle (same shape as macOS, flutter_pear-6yz's
// own offload-addons mechanism), not the mobile assets/pear-end.bundle:
// unlike mobile's addons (linked ahead of time into this same binary), a
// desktop bare subprocess loads addons from real `file:` prebuilds at
// runtime, which only the desktop-specific bundle ships alongside.
// The asset subpath already includes the owning package's directory
// (Linux's flat flutter_assets/packages/<pkg>/ layout, confirmed against a
// real build) -- no separate "fromPackage" lookup call exists on this
// platform the way iOS/macOS's FlutterDartProject API has one.
static const char* kBundleAssetSubpath =
    "packages/flutter_pear/assets/desktop/linux-x64/pear-end.bundle";

// Pin for the real, published `bare-runtime-linux-x64` npm package
// (Apache-2.0, github.com/holepunchto/bare-runtime) -- flutter_pear-8f6:
// so a flutter_pear Linux app can fetch its own `bare` runtime instead of
// requiring the end user to `npm i -g bare` first. Kept in sync by hand
// with `flutter_pear_bare/bare-runtime-pin.json`, the human-readable
// source of truth for this pin. Mirrors the macOS host's identical
// mechanism (FlutterPearBarePlugin.swift) -- see its own doc comment for
// why this fetches a plain npm tarball rather than going through any
// existing packaging pipeline.
static const char* kBareRuntimeUpstreamUrl =
    "https://registry.npmjs.org/bare-runtime-linux-x64/-/"
    "bare-runtime-linux-x64-1.30.3.tgz";
static const char* kBareRuntimeUpstreamSha256 =
    "ee9af7368e35dca777e2f768a6da536432517a8f6711dc7df7dca4b9535d9128";
static const char* kBareRuntimeVersion = "1.30.3";

// Worklet lifecycle (mirrors WorkletState in bare_worklet.dart). This
// comment block is duplicated VERBATIM in FlutterPearBarePlugin.kt/.swift,
// this file, and the Windows host (windows/flutter_pear_bare_plugin_impl.cpp)
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
// Linux-specific (flutter_pear-65g, E-D2c): same embedding shape as macOS
// (flutter_pear-71g, E-D2a) -- no BareKit equivalent exists for desktop, so
// this host spawns the real `bare` runtime as a SUBPROCESS (GSubprocess)
// and relays raw binary IPC over its stdin/stdout. `suspend`/`resume` are
// deliberate no-ops here, same rationale as macOS: desktop has no
// OS-imposed background execution limit, so there is nothing to pause.
// Reattach-across-hot-restart uses the SAME static-state-survives-a-
// plugin-reinit pattern the other hosts use.
struct _FlutterPearBarePlugin {
  GObject parent_instance;
  FlMethodChannel* control;
  FlBasicMessageChannel* ipc;
  gboolean attached;
};

G_DEFINE_TYPE(FlutterPearBarePlugin, flutter_pear_bare_plugin,
              g_object_get_type())

// Static, process-lifetime state (survives a hot-restart's plugin reinit --
// mirrors the other hosts' own static/class-level state).
static GSubprocess* g_worklet_process = nullptr;
static GOutputStream* g_worklet_stdin = nullptr;
static GInputStream* g_worklet_stdout = nullptr;
static int g_worklet_generation = 0;
static gboolean g_shutdown_hook_registered = FALSE;

static void relay_from_worklet(FlutterPearBarePlugin* self);
static void report_unexpected_exit(FlutterPearBarePlugin* self,
                                    const gchar* reason, int generation);
static void terminate_worklet_state();

// Kills the worklet subprocess on a NORMAL app quit (window close / Cmd-Q
// equivalent) -- flutter_pear-65g, mirrors the macOS host's own
// NSApplication.willTerminateNotification hook. Reached via the process's
// singleton GApplication rather than any consumer-side code change (no
// my_application.cc edit needed) -- this closes the orphaned-subprocess
// gap for a graceful quit; an external SIGKILL can never be intercepted by
// any in-process code, a fundamental OS limit, not a gap this fixes.
static void on_app_shutdown(GApplication* application, gpointer user_data) {
  if (g_worklet_process == nullptr) return;
  g_message(
      "FlutterPearBarePlugin (Linux): app shutting down, killing worklet "
      "subprocess");
  if (g_worklet_stdout != nullptr) {
    g_input_stream_close(g_worklet_stdout, nullptr, nullptr);
  }
  g_subprocess_force_exit(g_worklet_process);
  g_clear_object(&g_worklet_process);
  g_clear_object(&g_worklet_stdin);
  g_clear_object(&g_worklet_stdout);
}

static void register_shutdown_hook_once() {
  if (g_shutdown_hook_registered) return;
  GApplication* app = g_application_get_default();
  if (app == nullptr) return;  // registrar ran before the app registered; rare
  g_signal_connect(app, "shutdown", G_CALLBACK(on_app_shutdown), nullptr);
  g_shutdown_hook_registered = TRUE;
}

// Resolves the bundled pear-end.bundle's absolute path -- Linux's Flutter
// asset bundle is a flat, predictable layout (confirmed against a real
// build): <bundle_root>/data/flutter_assets/<asset_subpath>, with the
// executable itself living directly at <bundle_root>/<exe_name>. Unlike
// iOS/macOS, Linux's flutter_linux embedding exposes no asset-lookup
// helper on the plugin-registrar path, so this resolves the running
// executable's own directory via /proc/self/exe instead.
static gchar* resolve_bundle_path(GError** error) {
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", error);
  if (exe_path == nullptr) return nullptr;
  g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
  gchar* bundle_path = g_build_filename(exe_dir, "data", "flutter_assets",
                                         kBundleAssetSubpath, nullptr);
  return bundle_path;
}

// Where a fetched `bare` runtime is cached, once per pinned version -- the
// XDG data dir (same storage-root decision as pear-end's own storage
// above), just a different subdirectory. Versioned so bumping
// kBareRuntimeVersion naturally re-fetches instead of reusing a stale
// cached binary under the same path. Caller owns the returned string.
static gchar* cached_bare_runtime_path() {
  return g_build_filename(g_get_user_data_dir(), "flutter_pear",
                           "bare-runtime", kBareRuntimeVersion, "bare",
                           nullptr);
}

// Runs [argv] to completion (PATH-searched), discarding its output,
// returning TRUE only on a real zero exit -- FALSE for a spawn failure
// (e.g. the tool isn't installed) or a nonzero exit alike, since every
// caller here treats both the same way (fetch/extract failed, fall back).
static gboolean run_to_completion(const gchar* const* argv) {
  gint exit_status = 0;
  gboolean ok = g_spawn_sync(nullptr, const_cast<gchar**>(argv), nullptr,
                              G_SPAWN_SEARCH_PATH, nullptr, nullptr, nullptr,
                              nullptr, &exit_status, nullptr);
  return ok && exit_status == 0;
}

// Downloads kBareRuntimeUpstreamUrl via `curl` (near-universally present on
// Linux; simpler and more robust than linking libcurl or GIO's own HTTP
// backend, which isn't guaranteed present either -- matches this file's
// existing "shell out to a well-known system tool" convention, e.g.
// resolve_bundle_path's own /proc/self/exe read), verifies it against
// kBareRuntimeUpstreamSha256 BEFORE extracting anything, extracts just
// `package/bin/bare` via `tar`, and installs it at
// cached_bare_runtime_path(). Returns nullptr (never throws/sets an error
// the caller reports) on ANY failure -- a failed fetch is not fatal,
// resolve_bare_runtime() falls back to PATH resolution. Caller owns the
// returned string. flutter_pear-8f6: mirrors the macOS host's identical
// mechanism (FlutterPearBarePlugin.swift); verified live on a real Ubuntu
// machine over SSH -- both the fetch-success and checksum-rejection paths,
// not just a local compile.
static gchar* fetch_and_cache_bare_runtime() {
  g_autoptr(GError) tmp_error = nullptr;
  g_autofree gchar* tmp_dir =
      g_dir_make_tmp("flutter-pear-bare-fetch-XXXXXX", &tmp_error);
  if (tmp_dir == nullptr) return nullptr;

  auto cleanup_and_return = [&](gchar* result) -> gchar* {
    // Best-effort cleanup -- shell out to `rm -rf`, same "use the system's
    // own tool" convention as curl/tar below rather than a hand-rolled
    // recursive delete.
    const gchar* rm_argv[] = {"rm", "-rf", tmp_dir, nullptr};
    run_to_completion(rm_argv);
    return result;
  };

  g_autofree gchar* tarball_path =
      g_build_filename(tmp_dir, "bare-runtime.tgz", nullptr);
  const gchar* curl_argv[] = {"curl", "-sL", "--fail", "-o", tarball_path,
                               kBareRuntimeUpstreamUrl, nullptr};
  if (!run_to_completion(curl_argv)) return cleanup_and_return(nullptr);

  g_autofree gchar* tarball_contents = nullptr;
  gsize tarball_size = 0;
  if (!g_file_get_contents(tarball_path, &tarball_contents, &tarball_size,
                            nullptr)) {
    return cleanup_and_return(nullptr);
  }
  g_autofree gchar* actual_sha256 = g_compute_checksum_for_data(
      G_CHECKSUM_SHA256, reinterpret_cast<const guchar*>(tarball_contents),
      tarball_size);
  if (g_strcmp0(actual_sha256, kBareRuntimeUpstreamSha256) != 0) {
    g_warning(
        "FlutterPearBarePlugin (Linux): fetched bare-runtime tarball "
        "checksum mismatch (expected %s, got %s) -- refusing to use it",
        kBareRuntimeUpstreamSha256, actual_sha256);
    return cleanup_and_return(nullptr);
  }

  const gchar* tar_argv[] = {"tar", "-xzf", tarball_path, "-C", tmp_dir,
                              "package/bin/bare", nullptr};
  if (!run_to_completion(tar_argv)) return cleanup_and_return(nullptr);

  g_autofree gchar* extracted_binary =
      g_build_filename(tmp_dir, "package", "bin", "bare", nullptr);
  if (!g_file_test(extracted_binary, G_FILE_TEST_EXISTS)) {
    return cleanup_and_return(nullptr);
  }

  gchar* cache_path = cached_bare_runtime_path();
  g_autofree gchar* cache_dir = g_path_get_dirname(cache_path);
  if (g_mkdir_with_parents(cache_dir, 0700) != 0) {
    g_free(cache_path);
    return cleanup_and_return(nullptr);
  }
  // GFile::move (not a raw rename()) so a cross-filesystem move (e.g. /tmp
  // as tmpfs, XDG data dir on a different mount) is handled transparently
  // instead of failing with EXDEV.
  g_autoptr(GFile) src_file = g_file_new_for_path(extracted_binary);
  g_autoptr(GFile) dest_file = g_file_new_for_path(cache_path);
  if (!g_file_move(src_file, dest_file, G_FILE_COPY_OVERWRITE, nullptr,
                    nullptr, nullptr, nullptr)) {
    g_free(cache_path);
    return cleanup_and_return(nullptr);
  }
  g_chmod(cache_path, 0755);
  return cleanup_and_return(cache_path);
}

// Resolves the `bare` runtime for this run (flutter_pear-8f6): a
// previously-fetched, cached copy first (instant on every launch after the
// first), then a first-use fetch of the pinned npm-published binary,
// falling back to PATH resolution (g_find_program_in_path, today's
// dev-time-only mechanism) only if the fetch itself fails. Mirrors the
// macOS host's identically-named resolveBareRuntime() -- see its own doc
// comment for the blocking-fetch tradeoff, which applies here too (this
// call happens on start_worklet's own synchronous, non-async path).
// Caller owns the returned string.
static gchar* resolve_bare_runtime() {
  g_autofree gchar* cache_path = cached_bare_runtime_path();
  if (g_file_test(cache_path, G_FILE_TEST_IS_EXECUTABLE)) {
    return g_strdup(cache_path);
  }
  gchar* fetched = fetch_and_cache_bare_runtime();
  if (fetched != nullptr) return fetched;
  return g_find_program_in_path("bare");
}

// Returns true if this call reattached to an already-running worklet,
// false if it booted a fresh one.
static gboolean start_worklet(FlutterPearBarePlugin* self,
                               const gchar* bundle_path_arg, GError** error) {
  // Hot-restart safe: Dart state resets but the subprocess keeps running --
  // just re-point the read loop at the (new) Dart-side ipc. Every start()
  // call (fresh boot AND reattach) re-arms the relay so a hot restart's new
  // plugin instance keeps receiving data instead of a stale callback
  // silently dropping it (the exact bug fixed on the macOS host,
  // flutter_pear-iqp -- applied here from the start).
  if (g_worklet_process != nullptr) {
    relay_from_worklet(self);
    return TRUE;
  }

  g_autofree gchar* resolved_bundle_path = nullptr;
  if (bundle_path_arg != nullptr && strlen(bundle_path_arg) > 0) {
    resolved_bundle_path = g_strdup(bundle_path_arg);
  } else {
    resolved_bundle_path = resolve_bundle_path(error);
    if (resolved_bundle_path == nullptr) return FALSE;
    if (!g_file_test(resolved_bundle_path, G_FILE_TEST_EXISTS)) {
      g_set_error(error, g_quark_from_static_string("flutter_pear_bare"), 1,
                  "could not resolve the bundled %s asset",
                  kBundleAssetSubpath);
      return FALSE;
    }
  }

  // XDG data dir ($XDG_DATA_HOME, default ~/.local/share) -- the Linux
  // analogue of macOS's Application Support / Android's private filesDir
  // (Eng2 decision 35: never a cloud-synced location; g_get_user_data_dir()
  // is not synced by any Linux desktop environment by default, matching
  // that same "never let a backup/sync restore fork a Hypercore writer key
  // onto a second device" rationale).
  g_autofree gchar* storage_base =
      g_build_filename(g_get_user_data_dir(), "flutter_pear", nullptr);
  if (g_mkdir_with_parents(storage_base, 0700) != 0) {
    g_set_error(error, g_quark_from_static_string("flutter_pear_bare"), 2,
                "could not create storage directory %s", storage_base);
    return FALSE;
  }

  // pear-end/index.js's desktop branch expects the storage dir at
  // Bare.argv[2] (flutter_pear-71g's own pear-end fix, shared by every
  // desktop host): a real OS subprocess argv is
  // [bare-binary-path, script-path, storage-dir, ...] -- bare itself is
  // argv[0] here, resolved by resolve_bare_runtime() (flutter_pear-8f6:
  // prefers a fetched/cached binary over PATH, so end users don't need
  // `bare` preinstalled; GSubprocessLauncher does not search PATH on its
  // own either way, so the binary path must be resolved first regardless).
  g_autofree gchar* bare_path = resolve_bare_runtime();
  if (bare_path == nullptr) {
    g_set_error(error, g_quark_from_static_string("flutter_pear_bare"), 3,
                "the `bare` runtime was not found on PATH, and could not be "
                "fetched (flutter_pear-8f6)");
    return FALSE;
  }

  g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new(
      static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDIN_PIPE |
                                     G_SUBPROCESS_FLAGS_STDOUT_PIPE));
  // Inherit stderr (not piped) -- pear-end's own uncaughtException/
  // unhandledRejection handler already reports crashes over the IPC data
  // channel itself; stderr is a debugging convenience, not a signal this
  // host parses (matches every other desktop host).

  const gchar* argv[] = {bare_path, resolved_bundle_path, storage_base,
                          nullptr};
  GSubprocess* process =
      g_subprocess_launcher_spawnv(launcher, argv, error);
  if (process == nullptr) return FALSE;

  int active_generation = g_worklet_generation + 1;
  g_worklet_process = process;
  g_worklet_stdin = static_cast<GOutputStream*>(
      g_object_ref(g_subprocess_get_stdin_pipe(process)));
  g_worklet_stdout = static_cast<GInputStream*>(
      g_object_ref(g_subprocess_get_stdout_pipe(process)));
  g_worklet_generation = active_generation;

  // Watches for the subprocess exiting on its own (crash or clean exit) --
  // the E2.6 backstop, mirrored from every other host.
  g_subprocess_wait_async(
      process, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer user_data) {
        auto* self = FLUTTER_PEAR_BARE_PLUGIN(user_data);
        GSubprocess* proc = G_SUBPROCESS(source);
        int generation = g_worklet_generation;
        g_subprocess_wait_finish(proc, result, nullptr);
        if (self->attached) {
          g_autofree gchar* reason = g_strdup_printf(
              "bare subprocess exited (status %d)",
              g_subprocess_get_exit_status(proc));
          report_unexpected_exit(self, reason, generation);
        }
        g_object_unref(self);
      },
      g_object_ref(self));

  relay_from_worklet(self);
  return FALSE;
}

// Arms the worklet -> Dart read loop against the CURRENT plugin instance's
// `ipc` channel -- called on every start() (both a fresh boot and a
// reattach), mirroring every other host's identically-purposed
// relayFromWorklet(). Reads off the static g_worklet_stdout (survives a
// hot restart) rather than a locally-captured stream, so a reattach can
// re-point the callback at a plugin instance that didn't exist when the
// stream was created.
static void relay_from_worklet(FlutterPearBarePlugin* self) {
  if (g_worklet_stdout == nullptr) return;
  int generation = g_worklet_generation;
  g_input_stream_read_bytes_async(
      g_worklet_stdout, 65536, G_PRIORITY_DEFAULT, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer user_data) {
        auto* self = FLUTTER_PEAR_BARE_PLUGIN(user_data);
        int generation = GPOINTER_TO_INT(g_object_get_data(
            G_OBJECT(self), "flutter-pear-bare-relay-generation"));
        g_autoptr(GError) error = nullptr;
        g_autoptr(GBytes) bytes = g_input_stream_read_bytes_finish(
            G_INPUT_STREAM(source), result, &error);
        // Stale-callback guard: a reattach/terminate may have already
        // moved on to a different generation by the time this completes.
        if (generation != g_worklet_generation) {
          g_object_unref(self);
          return;
        }
        if (bytes == nullptr || g_bytes_get_size(bytes) == 0) {
          // EOF (or a read error) -- the subprocess closed its output,
          // whether via a clean exit or a crash. The wait_async callback
          // above reports the exit itself; this just stops reading.
          g_object_unref(self);
          return;
        }
        if (self->attached) {
          size_t size = 0;
          gconstpointer data = g_bytes_get_data(bytes, &size);
          g_autoptr(FlValue) value = fl_value_new_uint8_list(
              static_cast<const uint8_t*>(data), size);
          fl_basic_message_channel_send(self->ipc, value, nullptr, nullptr,
                                        nullptr);
        }
        relay_from_worklet(self);
        g_object_unref(self);
      },
      g_object_ref(self));
  g_object_set_data(G_OBJECT(self), "flutter-pear-bare-relay-generation",
                    GINT_TO_POINTER(generation));
}

// Tears down this generation's static state (so the next start_worklet()
// boots fresh instead of "reattaching" to a subprocess that's actually
// gone) and notifies Dart via the control channel with `reason`. Mirrors
// every other host's identically-named method.
static void report_unexpected_exit(FlutterPearBarePlugin* self,
                                    const gchar* reason, int generation) {
  if (generation != g_worklet_generation || g_worklet_process == nullptr) {
    return;  // already torn down by terminate(), or a stale generation
  }
  g_message("FlutterPearBarePlugin (Linux): worklet exited unexpectedly: %s",
            reason);
  g_clear_object(&g_worklet_process);
  g_clear_object(&g_worklet_stdin);
  g_clear_object(&g_worklet_stdout);
  if (!self->attached) return;
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "reason", fl_value_new_string(reason));
  fl_value_set_string_take(args, "generationId", fl_value_new_int(generation));
  fl_method_channel_invoke_method(self->control, "onWorkletExit", args,
                                  nullptr, nullptr, nullptr);
}

static void terminate_worklet_state() {
  GSubprocess* process = g_worklet_process;
  g_worklet_process = nullptr;
  g_worklet_stdin = nullptr;
  GInputStream* stdout_to_close = g_worklet_stdout;
  g_worklet_stdout = nullptr;
  // Close stdout BEFORE terminating so the intentional stop below is never
  // reported as an unexpected exit -- same ordering rationale as every
  // other host's terminateWorklet().
  if (stdout_to_close != nullptr) {
    g_input_stream_close(stdout_to_close, nullptr, nullptr);
    g_object_unref(stdout_to_close);
  }
  if (process != nullptr) {
    g_subprocess_force_exit(process);
    g_object_unref(process);
  }
}

static void flutter_pear_bare_plugin_handle_method_call(
    FlutterPearBarePlugin* self, FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "start") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    const gchar* bundle_path_arg = nullptr;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* bp = fl_value_lookup_string(args, "bundlePath");
      if (bp != nullptr && fl_value_get_type(bp) == FL_VALUE_TYPE_STRING) {
        bundle_path_arg = fl_value_get_string(bp);
      }
    }
    g_autoptr(GError) error = nullptr;
    gboolean reattached = start_worklet(self, bundle_path_arg, &error);
    if (error != nullptr) {
      // Distinct code for the bare-not-on-PATH case (flutter_pear-a4p,
      // error code 3 from start_worklet's own g_set_error above) so the
      // Dart side can surface a typed, actionable PearException instead of
      // a generic start failure -- see Pear.start's own translation of
      // this code.
      const gchar* flutter_error_code =
          error->code == 3 ? "bare_runtime_missing" : "worklet_start_failed";
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          flutter_error_code, error->message, nullptr));
    } else {
      g_autoptr(FlValue) result = fl_value_new_map();
      fl_value_set_string_take(result, "reattached",
                               fl_value_new_bool(reattached));
      fl_value_set_string_take(result, "generationId",
                               fl_value_new_int(g_worklet_generation));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (strcmp(method, "suspend") == 0 || strcmp(method, "resume") == 0) {
    // Deliberate no-op (flutter_pear-65g), same rationale as macOS: desktop
    // has no OS-imposed background execution limit, so there is nothing to
    // pause -- ack rather than not-implemented so Dart's own no-op-safe
    // suspend()/resume() doesn't throw calling these.
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "terminate") == 0) {
    terminate_worklet_state();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  auto* plugin = FLUTTER_PEAR_BARE_PLUGIN(user_data);
  flutter_pear_bare_plugin_handle_method_call(plugin, method_call);
}

static void ipc_message_cb(FlBasicMessageChannel* channel, FlValue* message,
                           FlBasicMessageChannelResponseHandle* response_handle,
                           gpointer user_data) {
  if (message != nullptr &&
      fl_value_get_type(message) == FL_VALUE_TYPE_UINT8_LIST &&
      g_worklet_stdin != nullptr) {
    size_t length = fl_value_get_length(message);
    const uint8_t* data = fl_value_get_uint8_list(message);
    g_output_stream_write_all(g_worklet_stdin, data, length, nullptr, nullptr,
                              nullptr);
  }
  auto* channel_obj = FL_BASIC_MESSAGE_CHANNEL(channel);
  fl_basic_message_channel_respond(channel_obj, response_handle, nullptr,
                                   nullptr);
}

static void flutter_pear_bare_plugin_dispose(GObject* object) {
  auto* self = FLUTTER_PEAR_BARE_PLUGIN(object);
  self->attached = FALSE;
  g_clear_object(&self->control);
  g_clear_object(&self->ipc);
  G_OBJECT_CLASS(flutter_pear_bare_plugin_parent_class)->dispose(object);
}

static void flutter_pear_bare_plugin_class_init(
    FlutterPearBarePluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_pear_bare_plugin_dispose;
}

static void flutter_pear_bare_plugin_init(FlutterPearBarePlugin* self) {
  self->attached = TRUE;
}

void flutter_pear_bare_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlutterPearBarePlugin* plugin = FLUTTER_PEAR_BARE_PLUGIN(
      g_object_new(flutter_pear_bare_plugin_get_type(), nullptr));

  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);

  FlMethodChannel* control = fl_method_channel_new(
      messenger, "flutter_pear_bare/control",
      FL_METHOD_CODEC(fl_standard_method_codec_new()));
  plugin->control = control;
  fl_method_channel_set_method_call_handler(control, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  FlBasicMessageChannel* ipc = fl_basic_message_channel_new(
      messenger, "flutter_pear_bare/ipc",
      FL_MESSAGE_CODEC(fl_standard_message_codec_new()));
  plugin->ipc = ipc;
  fl_basic_message_channel_set_message_handler(ipc, ipc_message_cb,
                                               g_object_ref(plugin),
                                               g_object_unref);

  register_shutdown_hook_once();

  g_object_unref(plugin);
}
