// The C side of the ArkTS host: the NAPI module the page imports, which
// starts Go and carries the messages of package wire between it and the
// host, and reports the surface ArkUI made for the XComponent.
//
// Go runs on a thread of its own. Calls Go makes of the host arrive here
// (mygo_ohos_call) only while ArkTS drains them, on the JS thread, which
// is this platform's UI thread; mygo_ohos_post asks ArkTS to drain.

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <napi/native_api.h>

#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#define LOG_DOMAIN 0xD002  // hilog takes 0x0 to 0xFFFFF: a bigger one logs nothing
#define LOG_TAG "MYGO"
#define LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

// The c-archive of the app (glue_ohos.go).
extern "C" {
void mygo_start_ohos(void);
void mygo_event(uint8_t *msg, size_t n, int onUI, uint8_t **reply, size_t *replyLen);
void mygo_drain(void);
}

// What napi_init.cpp provides to Go.
extern "C" void mygo_ohos_call(uint8_t *msg, size_t len, uint8_t **reply, size_t *replyLen);
extern "C" void mygo_ohos_post(void);
extern "C" void mygo_ohos_log(int error, uint8_t *line, size_t len);

namespace {

napi_env g_env = nullptr;
napi_ref g_dispatch = nullptr;   // (Uint8Array) => Uint8Array | null
napi_ref g_surface = nullptr;    // (handle, width, height, scale) => void
napi_ref g_touch = nullptr;      // (phase, x, y) => void
napi_threadsafe_function g_post = nullptr;
napi_threadsafe_function g_calls = nullptr;  // calls of Go's for the JS thread

// A window of the app's draws with a component of its own: the surface ArkUI
// made for it, which Go draws into.
struct windowComponent {
    OH_NativeXComponent *component = nullptr;
    uint64_t handle = 0;
};

// g_windows is the components, by the window they draw for; g_unbound those
// the module was loaded with, before the page said which window it is.
std::map<int, windowComponent> g_windows;
std::vector<OH_NativeXComponent *> g_unbound;
// The surface a component was given before the page said which window it
// draws for.
std::map<OH_NativeXComponent *, uint64_t> g_early;

// componentName is the name the page gave the component.
std::string componentName(OH_NativeXComponent *component) {
    char name[64] = {0};
    uint64_t size = sizeof(name);
    if (OH_NativeXComponent_GetXComponentId(component, name, &size) != 0) {
        return "";
    }
    return std::string(name);
}

// windowOf is the window a component draws for, or 0.
int windowOf(OH_NativeXComponent *component) {
    for (const auto &w : g_windows) {
        if (w.second.component == component) {
            return w.first;
        }
    }
    return 0;
}

// componentOf is the component a window draws with, or nullptr.
OH_NativeXComponent *componentOf(int id) {
    auto it = g_windows.find(id);
    return it == g_windows.end() ? nullptr : it->second.component;
}

// The JS thread: the only one a call of Go's may reach the host on.
pid_t g_jsThread = 0;

// postJS runs on the JS thread: ArkTS drains the calls Go made.
void postJS(napi_env env, napi_value cb, void *, void *) {
    if (env == nullptr || cb == nullptr) {
        return;
    }
    napi_value global = nullptr;
    napi_value result = nullptr;
    napi_get_global(env, &global);
    napi_call_function(env, global, cb, 0, nullptr, &result);
}

// callSurface reports the window ArkUI made, or 0 when it is gone.
void callSurface(int id, uint64_t handle, double width, double height, double scale) {
    if (g_env == nullptr || g_surface == nullptr) {
        return;
    }
    napi_handle_scope scope;
    if (napi_open_handle_scope(g_env, &scope) != napi_ok) {
        return;
    }
    napi_value cb = nullptr;
    napi_value global = nullptr;
    napi_value result = nullptr;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    double args[4] = {static_cast<double>(handle), width, height, scale};
    napi_get_reference_value(g_env, g_surface, &cb);
    napi_get_global(g_env, &global);
    napi_create_int32(g_env, id, &argv[0]);
    for (int i = 0; i < 4; i++) {
        napi_create_double(g_env, args[i], &argv[i + 1]);
    }
    if (cb != nullptr) {
        napi_status st = napi_call_function(g_env, global, cb, 5, argv, &result);
        if (st != napi_ok) {
            LOGE("MYGO the host did not take the surface: %{public}d", static_cast<int>(st));
        }
    }
    napi_close_handle_scope(g_env, scope);
}

void OnSurfaceCreated(OH_NativeXComponent *component, void *window) {
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    const int id = windowOf(component);
    g_windows[id].handle = reinterpret_cast<uint64_t>(window);
    g_early[component] = reinterpret_cast<uint64_t>(window);
    LOGI("MYGO surface of %{public}d %{public}lx %{public}lux%{public}lu", id, (unsigned long)window,
         (unsigned long)width, (unsigned long)height);
    callSurface(id, reinterpret_cast<uint64_t>(window), static_cast<double>(width), static_cast<double>(height), 1);
}

// The size is asked for, not given: the callback has only the window.
void OnSurfaceChanged(OH_NativeXComponent *component, void *window) {
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    const int id = windowOf(component);
    g_windows[id].handle = reinterpret_cast<uint64_t>(window);
    LOGI("MYGO surface of %{public}d changed %{public}lux%{public}lu", id, (unsigned long)width, (unsigned long)height);
    callSurface(id, reinterpret_cast<uint64_t>(window), static_cast<double>(width), static_cast<double>(height), 1);
}

// DispatchTouchEvent is where a surface's fingers come: ArkUI's own
// onTouch does not see them, as the surface is the app's.
void DispatchTouchEvent(OH_NativeXComponent *component, void *window) {
    OH_NativeXComponent_TouchEvent te;
    if (OH_NativeXComponent_GetTouchEvent(component, window, &te) != 0) {
        return;
    }
    const char *phase = nullptr;
    switch (te.type) {
        case OH_NATIVEXCOMPONENT_DOWN:
            phase = "down";
            break;
        case OH_NATIVEXCOMPONENT_MOVE:
            phase = "move";
            break;
        case OH_NATIVEXCOMPONENT_UP:
            phase = "up";
            break;
        case OH_NATIVEXCOMPONENT_CANCEL:
            phase = "cancel";
            break;
        default:
            return;
    }
    if (te.numPoints < 1 || g_env == nullptr || g_touch == nullptr) {
        return;
    }
    const OH_NativeXComponent_TouchPoint &p = te.touchPoints[0];
    if (te.type != OH_NATIVEXCOMPONENT_MOVE) {
        LOGI("MYGO touch %{public}s at %{public}d,%{public}d", phase, static_cast<int>(p.x),
             static_cast<int>(p.y));
    }
    napi_handle_scope scope;
    if (napi_open_handle_scope(g_env, &scope) != napi_ok) {
        return;
    }
    napi_value cb = nullptr;
    napi_value global = nullptr;
    napi_value result = nullptr;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_create_int32(g_env, windowOf(component), &argv[0]);
    napi_create_string_utf8(g_env, phase, NAPI_AUTO_LENGTH, &argv[1]);
    napi_create_double(g_env, p.x, &argv[2]);
    napi_create_double(g_env, p.y, &argv[3]);
    napi_get_reference_value(g_env, g_touch, &cb);
    napi_get_global(g_env, &global);
    if (cb != nullptr) {
        napi_call_function(g_env, global, cb, 4, argv, &result);
    }
    napi_close_handle_scope(g_env, scope);
}

void OnSurfaceDestroyed(OH_NativeXComponent *component, void *) {
    const int id = windowOf(component);
    LOGI("MYGO surface of %{public}d gone", id);
    g_windows[id].handle = 0;
    callSurface(id, 0, 0, 0, 1);
}

OH_NativeXComponent_Callback g_callbacks = {
    .OnSurfaceCreated = OnSurfaceCreated,
    .OnSurfaceChanged = OnSurfaceChanged,
    .OnSurfaceDestroyed = OnSurfaceDestroyed,
    .DispatchTouchEvent = DispatchTouchEvent,
};

// bytes copies a JS Uint8Array or ArrayBuffer, which Go frees.
bool bytes(napi_value value, uint8_t **out, size_t *n) {
    napi_valuetype t = napi_undefined;
    napi_typeof(g_env, value, &t);
    if (t != napi_object) {
        return false;
    }
    void *data = nullptr;
    size_t length = 0;
    bool typed = false;
    if (napi_get_typedarray_info(g_env, value, nullptr, &length, &data, nullptr, nullptr) == napi_ok) {
        typed = true;
    } else if (napi_get_arraybuffer_info(g_env, value, &data, &length) != napi_ok) {
        return false;
    }
    if (!typed && data == nullptr) {
        return false;
    }
    auto p = static_cast<uint8_t *>(std::malloc(length > 0 ? length : 1));
    if (p == nullptr) {
        return false;
    }
    if (length > 0) {
        std::memcpy(p, data, length);
    }
    *out = p;
    *n = length;
    return true;
}

// event hands Go an event of the host and returns Go's reply, if any.
napi_value event(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
        return nullptr;
    }
    uint8_t *msg = nullptr;
    size_t n = 0;
    if (!bytes(argv[0], &msg, &n)) {
        return nullptr;
    }
    uint8_t *reply = nullptr;
    size_t replyLen = 0;
    mygo_event(msg, n, 1, &reply, &replyLen);
    std::free(msg);
    if (reply == nullptr) {
        return nullptr;
    }
    napi_value out = nullptr;
    void *p = nullptr;
    if (napi_create_arraybuffer(env, replyLen, &p, &out) == napi_ok && replyLen > 0) {
        std::memcpy(p, reply, replyLen);
    }
    std::free(reply);
    return out;
}

napi_value drain(napi_env, napi_callback_info) {
    mygo_drain();
    return nullptr;
}


// bytes copies a JS Uint8Array or ArrayBuffer, which Go frees.
bool bytes(napi_value value, uint8_t **out, size_t *n);

// dispatchOnJS runs one call of Go's on the host. JS thread only: the env is
// the JS thread's, and a VM that is entered from another thread aborts
// ("ecma_vm cannot run in multi-thread").
void dispatchOnJS(const uint8_t *msg, size_t len, std::vector<uint8_t> &out) {
    if (g_env == nullptr || g_dispatch == nullptr) {
        return;
    }
    napi_handle_scope scope;
    if (napi_open_handle_scope(g_env, &scope) != napi_ok) {
        return;
    }
    void *data = nullptr;
    napi_value ab = nullptr;
    napi_value buf = nullptr;
    if (napi_create_arraybuffer(g_env, len > 0 ? len : 1, &data, &ab) == napi_ok && data != nullptr) {
        if (len > 0) {
            std::memcpy(data, msg, len);
        }
        // The host reads Uint8Array, not the ArrayBuffer it lies on.
        napi_create_typedarray(g_env, napi_uint8_array, len, ab, 0, &buf);
        napi_value dispatch = nullptr;
        napi_value global = nullptr;
        napi_value result = nullptr;
        napi_value argv[1] = {buf};
        napi_get_reference_value(g_env, g_dispatch, &dispatch);
        napi_get_global(g_env, &global);
        napi_status st = napi_call_function(g_env, global, dispatch, 1, argv, &result);
        if (st == napi_ok) {
            uint8_t *b = nullptr;
            size_t n = 0;
            if (bytes(result, &b, &n) && b != nullptr) {
                out.assign(b, b + n);
                free(b);
            }
        } else {
            LOGI("MYGO dispatch failed: %{public}d", static_cast<int>(st));
        }
    }
    napi_close_handle_scope(g_env, scope);
}

// A call of Go's from a thread that is not the JS thread's, which waits
// while the JS thread runs it: the sound writes on its own thread, and a
// Go thread's call into the VM is not the VM's to take.
struct crossCall {
    std::mutex mu;
    std::condition_variable cv;
    bool done = false;
    std::vector<uint8_t> msg;
    std::vector<uint8_t> out;
};

// callOnJS runs a queued call of Go's, on the JS thread.
void callOnJS(napi_env, napi_value, void *, void *data) {
    auto *c = static_cast<crossCall *>(data);
    std::vector<uint8_t> out;
    dispatchOnJS(c->msg.data(), c->msg.size(), out);
    {
        std::lock_guard<std::mutex> lock(c->mu);
        c->out.swap(out);
        c->done = true;
    }
    c->cv.notify_all();
}

// mygoComponentId is the XComponent the window draws with: the main one is
// 'mygo', and the others are named after their window.
std::string componentIdOf(int id) { return id <= 0 ? "mygo" : "mygo-" + std::to_string(id); }

// bind has the component the module was loaded with draw for window id: a
// window of the app's has a component of its own, and ArkUI loads the module
// once for each.
napi_value bind(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
        return nullptr;
    }
    int32_t id = 0;
    napi_get_value_int32(env, argv[0], &id);
    if (g_unbound.empty()) {
        // The page bound its component before Go named the window (to 0):
        // it draws for this one now.
        for (auto &w : g_windows) {
            if (w.second.component != nullptr && w.first <= 0) {
                g_windows[id] = w.second;
                g_windows.erase(w.first);
                if (g_windows[id].handle != 0) {
                    uint64_t sw = 0;
                    uint64_t sh = 0;
                    OH_NativeXComponent_GetXComponentSize(g_windows[id].component,
                                                          reinterpret_cast<void *>(g_windows[id].handle), &sw, &sh);
                    callSurface(id, g_windows[id].handle, static_cast<double>(sw), static_cast<double>(sh), 1);
                }
                LOGI("MYGO window %{public}d rebound", static_cast<int>(id));
                return nullptr;
            }
        }
        LOGE("MYGO bind %{public}d: no component", static_cast<int>(id));
        return nullptr;
    }
    const std::string want = componentIdOf(id);
    OH_NativeXComponent *found = nullptr;
    for (auto it = g_unbound.begin(); it != g_unbound.end(); ++it) {
        if (want == componentName(*it)) {
            found = *it;
            g_unbound.erase(it);
            break;
        }
    }
    if (found == nullptr) {
        // ArkUI may name it apart from us: the one left is the page's.
        found = g_unbound.back();
        g_unbound.pop_back();
        LOGI("MYGO bind %{public}d to %{public}s", static_cast<int>(id), componentName(found).c_str());
    }
    // A component draws for one window only.
    for (auto it = g_windows.begin(); it != g_windows.end();) {
        if (it->second.component == found && it->first != id) {
            it = g_windows.erase(it);
        } else {
            ++it;
        }
    }
    g_windows[id].component = found;
    auto early = g_early.find(found);
    if (early != g_early.end()) {
        g_windows[id].handle = early->second;
        g_early.erase(early);
    }
    LOGI("MYGO window %{public}d bound", static_cast<int>(id));
    if (g_windows[id].handle != 0) {
        uint64_t w = 0;
        uint64_t h = 0;
        OH_NativeXComponent_GetXComponentSize(found, reinterpret_cast<void *>(g_windows[id].handle), &w, &h);
        callSurface(id, g_windows[id].handle, static_cast<double>(w), static_cast<double>(h), 1);
    }
    return nullptr;
}

// start begins Go. dispatch runs one call on the JS thread, onSurface
// reports the window, and onDrain asks ArkTS to drain Go's calls.
napi_value start(napi_env env, napi_callback_info info) {
    static bool begun = false;
    if (begun) {
        return nullptr;  // the page was built again: Go runs once
    }
    begun = true;
    LOGI("MYGO start");
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 4) {
        napi_throw_error(env, nullptr, "start(dispatch, onSurface, onDrain, onTouch)");
        return nullptr;
    }
    g_env = env;
    g_jsThread = static_cast<pid_t>(gettid());
    napi_create_reference(env, argv[0], 1, &g_dispatch);
    napi_create_reference(env, argv[1], 1, &g_surface);
    napi_create_reference(env, argv[3], 1, &g_touch);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "mygoDrain", NAPI_AUTO_LENGTH, &name);
    if (napi_create_threadsafe_function(env, argv[2], nullptr, name, 0, 1, nullptr, nullptr, nullptr, postJS,
                                        &g_post) != napi_ok) {
        LOGE("MYGO no threadsafe function");
    }
    // The calls of Go's a thread of its own makes, carried to this one.
    napi_value callsName = nullptr;
    napi_create_string_utf8(env, "mygoCalls", NAPI_AUTO_LENGTH, &callsName);
    if (napi_create_threadsafe_function(env, nullptr, nullptr, callsName, 0, 1, nullptr, nullptr, nullptr, callOnJS,
                                        &g_calls) != napi_ok) {
        LOGE("MYGO no threadsafe function for calls");
    }
    mygo_start_ohos();
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    // ArkUI hands the XComponent to the module that made it, by name: the
    // page says which window it draws for (bind), as a window of the app's
    // has a component of its own.
    napi_value xcomponent = nullptr;
    napi_valuetype t = napi_undefined;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcomponent) == napi_ok) {
        napi_typeof(env, xcomponent, &t);
        OH_NativeXComponent *component = nullptr;
        if (t == napi_object && napi_unwrap(env, xcomponent, reinterpret_cast<void **>(&component)) == napi_ok &&
            component != nullptr) {
            g_unbound.push_back(component);
            // Registered before the page says which window it draws for: a
            // surface made before that still comes to these callbacks.
            OH_NativeXComponent_RegisterCallback(component, &g_callbacks);
            LOGI("MYGO component %{public}s", componentName(component).c_str());
        }
    }
    napi_property_descriptor desc[] = {
        {"bind", nullptr, bind, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"event", nullptr, event, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"drain", nullptr, drain, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace


// What Go calls: one call of the host, on the JS thread.
extern "C" void mygo_ohos_call(uint8_t *msg, size_t len, uint8_t **reply, size_t *replyLen) {
    *reply = nullptr;
    *replyLen = 0;
    const pid_t tid = static_cast<pid_t>(gettid());
    if (g_jsThread != 0 && tid != g_jsThread) {
        // Queued for the JS thread, which runs it as soon as it can: the
        // call waits, and a call that waits too long is dropped rather than
        // wedging the thread that made it (the sound's is a stream of them).
        if (g_calls == nullptr) {
            return;
        }
        crossCall c;
        c.msg.assign(msg, msg + len);
        if (napi_call_threadsafe_function(g_calls, &c, napi_tsfn_blocking) != napi_ok) {
            return;
        }
        std::unique_lock<std::mutex> lock(c.mu);
        if (!c.cv.wait_for(lock, std::chrono::seconds(2), [&c] { return c.done; })) {
            LOGE("MYGO call %{public}d of %{public}d bytes waited 2s for the JS thread",
                 len > 0 ? msg[0] : -1, static_cast<int>(len));
            return;
        }
        if (c.out.empty()) {
            return;
        }
        auto *p = static_cast<uint8_t *>(malloc(c.out.size()));
        if (p == nullptr) {
            return;
        }
        std::memcpy(p, c.out.data(), c.out.size());
        *reply = p;
        *replyLen = c.out.size();
        return;
    }
    std::vector<uint8_t> out;
    dispatchOnJS(msg, len, out);
    if (out.empty()) {
        return;
    }
    auto *p = static_cast<uint8_t *>(malloc(out.size()));
    if (p == nullptr) {
        return;
    }
    std::memcpy(p, out.data(), out.size());
    *reply = p;
    *replyLen = out.size();
}

// What Go calls: a line the app wrote to its standard output or error.
extern "C" void mygo_ohos_log(int error, uint8_t *line, size_t len) {
    // hilog prints %s as <private>: the line goes in a string it reads as is.
    char buf[512];
    size_t n = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
    std::memcpy(buf, line, n);
    buf[n] = '\0';
    OH_LOG_Print(LOG_APP, error ? LOG_ERROR : LOG_INFO, LOG_DOMAIN, "Go", "%{public}s", buf);
}

// What Go calls: ArkTS drains its calls, soon.
extern "C" void mygo_ohos_post(void) {
    if (g_post != nullptr) {
        napi_call_threadsafe_function(g_post, nullptr, napi_tsfn_nonblocking);
    }
}

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) { napi_module_register(&g_module); }
