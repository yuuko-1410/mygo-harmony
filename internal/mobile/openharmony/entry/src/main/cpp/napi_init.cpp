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

#include <cstdint>
#include <cstdlib>
#include <cstring>

#define LOG_DOMAIN 0xA0D002
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
napi_threadsafe_function g_post = nullptr;
OH_NativeXComponent *g_component = nullptr;

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
void callSurface(uint64_t handle, double width, double height, double scale) {
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
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    double args[4] = {static_cast<double>(handle), width, height, scale};
    napi_get_reference_value(g_env, g_surface, &cb);
    napi_get_global(g_env, &global);
    for (int i = 0; i < 4; i++) {
        napi_create_double(g_env, args[i], &argv[i]);
    }
    if (cb != nullptr) {
        napi_call_function(g_env, global, cb, 4, argv, &result);
    }
    napi_close_handle_scope(g_env, scope);
}

void OnSurfaceCreated(OH_NativeXComponent *, void *window) {
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(g_component, window, &width, &height);
    LOGI("MYGO surface %{public}lx %{public}lux%{public}lu", (unsigned long)window, (unsigned long)width,
         (unsigned long)height);
    callSurface(reinterpret_cast<uint64_t>(window), static_cast<double>(width), static_cast<double>(height), 1);
}

// The size is asked for, not given: the callback has only the window.
void OnSurfaceChanged(OH_NativeXComponent *, void *window) {
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(g_component, window, &width, &height);
    LOGI("MYGO surface changed %{public}lx %{public}lux%{public}lu", (unsigned long)window, (unsigned long)width,
         (unsigned long)height);
    callSurface(reinterpret_cast<uint64_t>(window), static_cast<double>(width), static_cast<double>(height), 1);
}

void OnSurfaceDestroyed(OH_NativeXComponent *, void *) {
    LOGI("MYGO surface gone");
    callSurface(0, 0, 0, 1);
}

OH_NativeXComponent_Callback g_callbacks = {
    .OnSurfaceCreated = OnSurfaceCreated,
    .OnSurfaceChanged = OnSurfaceChanged,
    .OnSurfaceDestroyed = OnSurfaceDestroyed,
    .DispatchTouchEvent = nullptr,
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

// start begins Go. dispatch runs one call on the JS thread, onSurface
// reports the window, and onDrain asks ArkTS to drain Go's calls.
napi_value start(napi_env env, napi_callback_info info) {
    LOGI("MYGO start");
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 3) {
        napi_throw_error(env, nullptr, "start(dispatch, onSurface, onDrain)");
        return nullptr;
    }
    g_env = env;
    napi_create_reference(env, argv[0], 1, &g_dispatch);
    napi_create_reference(env, argv[1], 1, &g_surface);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "mygoDrain", NAPI_AUTO_LENGTH, &name);
    if (napi_create_threadsafe_function(env, argv[2], nullptr, name, 0, 1, nullptr, nullptr, nullptr, postJS,
                                        &g_post) != napi_ok) {
        LOGE("MYGO no threadsafe function");
    }
    mygo_start_ohos();
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    LOGI("MYGO init");
    // ArkUI hands the XComponent to the module that made it, by name.
    napi_value xcomponent = nullptr;
    napi_valuetype t = napi_undefined;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcomponent) == napi_ok) {
        napi_typeof(env, xcomponent, &t);
        if (t == napi_object && napi_unwrap(env, xcomponent, reinterpret_cast<void **>(&g_component)) == napi_ok &&
            g_component != nullptr) {
            OH_NativeXComponent_RegisterCallback(g_component, &g_callbacks);
            LOGI("MYGO xcomponent registered");
        }
    }
    napi_property_descriptor desc[] = {
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
    if (g_env == nullptr || g_dispatch == nullptr) {
        return;
    }
    napi_handle_scope scope;
    if (napi_open_handle_scope(g_env, &scope) != napi_ok) {
        return;
    }
    void *data = nullptr;
    napi_value buf = nullptr;
    if (napi_create_arraybuffer(g_env, len > 0 ? len : 1, &data, &buf) == napi_ok && data != nullptr) {
        if (len > 0) {
            std::memcpy(data, msg, len);
        }
        napi_value dispatch = nullptr;
        napi_value global = nullptr;
        napi_value result = nullptr;
        napi_value argv[1] = {buf};
        napi_get_reference_value(g_env, g_dispatch, &dispatch);
        napi_get_global(g_env, &global);
        if (napi_call_function(g_env, global, dispatch, 1, argv, &result) == napi_ok) {
            bytes(result, reply, replyLen);
        }
    }
    napi_close_handle_scope(g_env, scope);
}

// What Go calls: a line the app wrote to its standard output or error.
extern "C" void mygo_ohos_log(int error, uint8_t *line, size_t len) {
    OH_LOG_Print(LOG_APP, error ? LOG_ERROR : LOG_INFO, LOG_DOMAIN, "Go", "%.*s", static_cast<int>(len),
                 reinterpret_cast<const char *>(line));
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
