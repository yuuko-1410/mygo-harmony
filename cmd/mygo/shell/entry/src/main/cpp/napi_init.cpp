// MyGo's host on HarmonyOS: an ArkTS page makes an XComponent, this module
// takes its OHNativeWindow and input events, and hands them to the Go
// runtime MyGo runs in. Calls the other way (clipboard, dialogs, the
// keyboard) go through a threadsafe function to ArkTS.
#include "napi/native_api.h"
#include "ace/xcomponent/native_interface_xcomponent.h"
#include <hilog/log.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include "native_buffer/buffer_common.h"
#include "native_window/external_window.h"

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0xD002, "MYGO", __VA_ARGS__)

// ---- the Go side (libapp.a) ----
extern "C" {
void mygo_start(char *filesDir);
void mygo_surface_created(uintptr_t native, double width, double height, double scale);
void mygo_surface_created_id(unsigned long long id, uintptr_t native, double width, double height, double scale);
void mygo_surface_resized(double width, double height, double scale);
void mygo_surface_resized_id(unsigned long long id, double width, double height, double scale);
void mygo_surface_destroyed();
void mygo_surface_shown(int shown);
void mygo_touch(int phase, int id, double x, double y, double pressure);
void mygo_mouse(int phase, double x, double y, int button);
void mygo_key(int down, int code, char *text);
void mygo_scroll(double dx, double dy);
void mygo_scroll_at(double dx, double dy, double x, double y);
void mygo_resize_id(int id, double width, double height, double scale);
void mygo_frame();
void mygo_quit();
void mygo_text_input(char *json);
void mygo_host_reply(char *json);
void mygo_window_closed(int id);
}

static double g_density = 1.0;

// Logs what the Go runtime writes to its standard output and error.
extern "C" void mygo_log(int level, char *line, int len) {
    OH_LOG_Print(LOG_APP, level == 0 ? LOG_INFO : LOG_ERROR, 0xD002, "MYGO", "%{public}s", line);
}

// ---- XComponent events ----

static unsigned long long ComponentID(OH_NativeXComponent *component) {
    char buf[64] = {0};
    uint64_t size = sizeof(buf) - 1;
    if (OH_NativeXComponent_GetXComponentId(component, buf, &size) != 0) {
        return 0;
    }
    unsigned long long id = 0;
    for (uint64_t i = 0; i < size; i++) {
        if (buf[i] >= '0' && buf[i] <= '9') {
            id = id * 10 + (unsigned long long)(buf[i] - '0');
        }
    }
    return id;
}

static void OnSurfaceCreatedCB(OH_NativeXComponent *component, void *window) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    OH_NativeWindow_SetColorSpace(static_cast<OHNativeWindow *>(window), OH_COLORSPACE_BT709_FULL);
    OH_NativeBuffer_ColorSpace cs = OH_COLORSPACE_NONE;
    OH_NativeWindow_GetColorSpace(static_cast<OHNativeWindow *>(window), &cs);
    LOGI("surface colorspace=%{public}d", (int)cs);
    LOGI("surface created size=%{public}llux%{public}llu density=%{public}f",
         (unsigned long long)w, (unsigned long long)h, g_density);
    mygo_surface_created_id(ComponentID(component), reinterpret_cast<uintptr_t>(window), (double)w, (double)h, g_density);
}

static void OnSurfaceChangedCB(OH_NativeXComponent *component, void *window) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    LOGI("surface changed size=%{public}llux%{public}llu", (unsigned long long)w, (unsigned long long)h);
    mygo_surface_resized_id(ComponentID(component), (double)w, (double)h, g_density);
}

static void OnSurfaceDestroyedCB(OH_NativeXComponent *component, void *window) {
    LOGI("surface destroyed");
    mygo_surface_destroyed();
}

static void OnSurfaceShowCB(OH_NativeXComponent *component, void *window) {
    mygo_surface_shown(1);
}

static void OnSurfaceHideCB(OH_NativeXComponent *component, void *window) {
    mygo_surface_shown(0);
}

static void OnFrameCB(OH_NativeXComponent *component, uint64_t timestamp, uint64_t targetTimestamp) {
    mygo_frame();
}

static void DispatchTouchEventCB(OH_NativeXComponent *component, void *window) {
    OH_NativeXComponent_TouchEvent event;
    if (OH_NativeXComponent_GetTouchEvent(component, window, &event) != 0 || event.numPoints == 0) {
        return;
    }
    int phase = 1;
    switch (event.type) {
        case OH_NATIVEXCOMPONENT_DOWN: phase = 0; break;
        case OH_NATIVEXCOMPONENT_UP: phase = 2; break;
        case OH_NATIVEXCOMPONENT_CANCEL: phase = 3; break;
        default: phase = 1; break;
    }
    mygo_touch(phase, (int)event.touchPoints[0].id,
               event.touchPoints[0].x / g_density, event.touchPoints[0].y / g_density, 0.0);
}

static void DispatchMouseEventCB(OH_NativeXComponent *component, void *window) {
    OH_NativeXComponent_MouseEvent ev;
    if (OH_NativeXComponent_GetMouseEvent(component, window, &ev) != 0) {
        return;
    }
    int phase = 1;
    switch (ev.action) {
        case OH_NATIVEXCOMPONENT_MOUSE_PRESS: phase = 0; break;
        case OH_NATIVEXCOMPONENT_MOUSE_RELEASE: phase = 2; break;
        case OH_NATIVEXCOMPONENT_MOUSE_CANCEL: phase = 3; break;
        default: phase = 1; break;
    }
    int button = 0;
    if (ev.button == OH_NATIVEXCOMPONENT_RIGHT_BUTTON) {
        button = 1;
    } else if (ev.button == OH_NATIVEXCOMPONENT_MIDDLE_BUTTON) {
        button = 2;
    }
    mygo_mouse(phase, ev.x / g_density, ev.y / g_density, button);
}

static void MouseHoverCB(OH_NativeXComponent *component, bool isHover) {}

static void DispatchKeyEventCB(OH_NativeXComponent *component, void *window) {
    OH_NativeXComponent_KeyEvent *ev = nullptr;
    if (OH_NativeXComponent_GetKeyEvent(component, &ev) != 0 || ev == nullptr) {
        return;
    }
    OH_NativeXComponent_KeyAction action = OH_NATIVEXCOMPONENT_KEY_ACTION_UNKNOWN;
    OH_NativeXComponent_GetKeyEventAction(ev, &action);
    OH_NativeXComponent_KeyCode code = static_cast<OH_NativeXComponent_KeyCode>(0);
    OH_NativeXComponent_GetKeyEventCode(ev, &code);
    mygo_key(action == OH_NATIVEXCOMPONENT_KEY_ACTION_UP ? 0 : 1, (int)code, nullptr);
}

static OH_NativeXComponent_Callback g_callback = {
    .OnSurfaceCreated = OnSurfaceCreatedCB,
    .OnSurfaceChanged = OnSurfaceChangedCB,
    .OnSurfaceDestroyed = OnSurfaceDestroyedCB,
    .DispatchTouchEvent = DispatchTouchEventCB,
};

static OH_NativeXComponent_MouseEvent_Callback g_mouse = {
    .DispatchMouseEvent = DispatchMouseEventCB,
    .DispatchHoverEvent = MouseHoverCB,
};

// ---- Go -> ArkTS ----

static napi_threadsafe_function g_textInput = nullptr;
static napi_threadsafe_function g_hostCall = nullptr;

extern "C" void mygo_host_textinput(char *json) {
    if (g_textInput == nullptr || json == nullptr) {
        return;
    }
    char *copy = strdup(json);
    if (copy == nullptr) {
        return;
    }
    if (napi_call_threadsafe_function(g_textInput, copy, napi_tsfn_nonblocking) != napi_ok) {
        free(copy);
    }
}

extern "C" void mygo_host_call(char *json) {
    if (g_hostCall == nullptr || json == nullptr) {
        return;
    }
    char *copy = strdup(json);
    if (copy == nullptr) {
        return;
    }
    if (napi_call_threadsafe_function(g_hostCall, copy, napi_tsfn_nonblocking) != napi_ok) {
        free(copy);
    }
}

static void CallJs(napi_env env, napi_value jsCb, void *context, void *data) {
    char *json = static_cast<char *>(data);
    if (env != nullptr && jsCb != nullptr) {
        napi_value arg;
        napi_create_string_utf8(env, json, NAPI_AUTO_LENGTH, &arg);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, jsCb, 1, &arg, nullptr);
    }
    free(json);
}

static void MakeThreadsafe(napi_env env, napi_value cb, const char *name,
                           napi_threadsafe_function *out) {
    if (*out != nullptr) {
        napi_release_threadsafe_function(*out, napi_tsfn_release);
        *out = nullptr;
    }
    napi_value resource;
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource);
    napi_create_threadsafe_function(env, cb, nullptr, resource, 0, 1, nullptr, nullptr, nullptr,
                                    CallJs, out);
}

// ---- NAPI ----

static napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    double density = 0;
    if (argc > 1) {
        napi_get_value_double(env, argv[1], &density);
    }
    if (density > 0) {
        g_density = density;
    }
    char filesDir[1024] = {0};
    size_t len = 0;
    if (argc > 0) {
        napi_get_value_string_utf8(env, argv[0], filesDir, sizeof(filesDir) - 1, &len);
    }
    LOGI("start density=%{public}f", g_density);
    mygo_start(filesDir);
    return nullptr;
}

// Resize takes the XComponent's size in vp and the density the vp are of:
// the host knows both, and its display's density may differ from the one
// that draws it.
static napi_value Resize(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    double wvp = 0, hvp = 0, density = 0;
    napi_get_value_double(env, argv[0], &wvp);
    napi_get_value_double(env, argv[1], &hvp);
    if (argc > 2) {
        napi_get_value_double(env, argv[2], &density);
    }
    if (density > 0) {
        g_density = density;
    }
    mygo_surface_resized(wvp * g_density, hvp * g_density, g_density);
    return nullptr;
}

static napi_value SetTextInputListener(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    MakeThreadsafe(env, argv[0], "mygoTextInput", &g_textInput);
    LOGI("text input listener set");
    return nullptr;
}

static napi_value TextInputEvent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    char buf[4096] = {0};
    size_t len = 0;
    if (argc > 0) {
        napi_get_value_string_utf8(env, argv[0], buf, sizeof(buf) - 1, &len);
    }
    mygo_text_input(buf);
    return nullptr;
}

static napi_value SetHostCallListener(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    MakeThreadsafe(env, argv[0], "mygoHostCall", &g_hostCall);
    LOGI("host call listener set");
    return nullptr;
}

static napi_value ResizeId(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t id = 0;
    double w = 0, h = 0, density = 0;
    if (argc > 0) { napi_get_value_int32(env, argv[0], &id); }
    if (argc > 1) { napi_get_value_double(env, argv[1], &w); }
    if (argc > 2) { napi_get_value_double(env, argv[2], &h); }
    if (argc > 3) { napi_get_value_double(env, argv[3], &density); }
    mygo_resize_id(id, w, h, density);
    return nullptr;
}

static napi_value Scroll(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    double dx = 0, dy = 0, x = 0, y = 0;
    if (argc > 0) { napi_get_value_double(env, argv[0], &dx); }
    if (argc > 1) { napi_get_value_double(env, argv[1], &dy); }
    if (argc > 2) { napi_get_value_double(env, argv[2], &x); }
    if (argc > 3) { napi_get_value_double(env, argv[3], &y); }
    mygo_scroll_at(dx, dy, x, y);
    return nullptr;
}

static napi_value WindowClosed(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t id = 0;
    if (argc > 0) { napi_get_value_int32(env, argv[0], &id); }
    mygo_window_closed(id);
    return nullptr;
}

static napi_value HostReply(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    char buf[8192] = {0};
    size_t len = 0;
    if (argc > 0) {
        napi_get_value_string_utf8(env, argv[0], buf, sizeof(buf) - 1, &len);
    }
    mygo_host_reply(buf);
    return nullptr;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) == napi_ok) {
        OH_NativeXComponent *component = nullptr;
        if (napi_unwrap(env, exportInstance, reinterpret_cast<void **>(&component)) == napi_ok && component) {
            LOGI("registering XComponent callbacks");
            OH_NativeXComponent_RegisterCallback(component, &g_callback);
            OH_NativeXComponent_RegisterMouseEventCallback(component, &g_mouse);
            OH_NativeXComponent_RegisterKeyEventCallback(component, DispatchKeyEventCB);
            OH_NativeXComponent_RegisterOnFrameCallback(component, OnFrameCB);
            OH_NativeXComponent_RegisterSurfaceShowCallback(component, OnSurfaceShowCB);
            OH_NativeXComponent_RegisterSurfaceHideCallback(component, OnSurfaceHideCB);
        }
    }

    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resize", nullptr, Resize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setTextInputListener", nullptr, SetTextInputListener, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"textInputEvent", nullptr, TextInputEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setHostCallListener", nullptr, SetHostCallListener, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hostReply", nullptr, HostReply, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"windowClosed", nullptr, WindowClosed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"scroll", nullptr, Scroll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resizeId", nullptr, ResizeId, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&g_module);
}
