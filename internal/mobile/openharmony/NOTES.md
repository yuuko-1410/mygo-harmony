# An ArkTS host on `internal/mobile/wire`: what the platform needed

Measured on a HUAWEI MateBook Pro S (`MOR-M1`), HarmonyOS `MOR-W52 7.0.0.115`,
API 26, 2in1, with the toolchain of `tools/ohos-go` (`GOOS=openharmony`, which
the toolchain reports as `linux`). Everything below is something the host or
the core had to do that the protocol does not say, in the order it was
learned. Each was a symptom first, a cause second.

## The protocol

**`Ready` is the backend's, not the host's.** `Backend.postReady` sends it
before what the host sent; a host that sends one too closes `App.readyCh`
twice, and Go aborts with `close of closed channel` before any of its output
reaches the log. A crash traced through `runtime.closechan →
Application.handleReady` reads like a host bug and is a duplicated event.

**`Resized` is what makes a window draw.** `surface.draw` returns while
`w.width == 0`, and only `Resized` sets it: `SurfaceChanged` alone gives a
surface Go never draws on, and the window stays black with no error anywhere.

**A message crosses as a `Uint8Array`, not the `ArrayBuffer` under it.**
`WireReader` reads `buf.length` and indexes it; an ArrayBuffer answers
`undefined` to both, every call decodes as op 0, and every reply is nil. On
the NAPI side that is `napi_create_typedarray` over the arraybuffer.

**`Surface.Native()` must ask what the handle is, not where it came from.**
It asks `mapsSchemes` (`runtime.GOOS == "android"`), which is true on Android
for two unrelated reasons. OpenHarmony is a build tag of a `linux` toolchain,
so `runtime.GOOS` is `linux`, the answer was "layer", and `ui` made no
renderer at all — a black window, again with no error.

## The drawing

**The font manager knows ten families, and none of them has a Han
character.** `OH_Drawing_FontTextToGlyphs` maps 「中」 to glyph 0, and
`OH_Drawing_FontMgrMatchFamilyStyleCharacter` — the call meant for exactly
this — returns a typeface that has none either. `HarmonyOS_Sans_SC.ttf` in
`/system/fonts` has it, and `OH_Drawing_TypefaceCreateFromFile` opens it. Text
in Chinese, Japanese and Korean draws only when a rune the styled font cannot
map is set in a file the engine opened and checked for that rune.

**A `SURFACE` XComponent is a layer above ArkUI's.** Whatever ArkUI draws in
the same window is under it: a `Web` component in the window showed only
because the XComponent was taken out of the tree while a page was showing.
Pages inside a surface therefore get a window of their own
(`windowStage.createSubWindow`, `moveWindowTo`, `resize`), which also means
the covers Go sends — the places the content painted over a page — are not
honoured yet: a finger over one goes to the page.

## The system's own APIs

**`WebviewController` is the component's, not the page's.** Loading from
`aboutToAppear` throws `17100001 Init error. The WebviewController must be
associated with a Web component`; the load waits for `onControllerAttached`.

**Some calls the protocol waits for are asynchronous here.** The clipboard's
`getData` is a promise, and Go asks for it in the middle of a call, so the
host reads it between frames and keeps the text; a write lands in what is
kept too. Notifications answer once the system has them (`NotifyDone`), and
`1600004 Notification disabled` means the user has not allowed them yet,
which the host turns into `requestEnableNotification` and a second publish.

**A share is ShareKit's panel, not an `ohos.want.action.sendData`.** The
want goes to whatever app claims it — on this machine, a downloads one — and
looks like success. `systemShare.ShareController(...).show()` is the sheet.

**Permissions are the app's to request:** `ohos.permission.INTERNET` for a
page, `ohos.permission.GET_NETWORK_INFO` for `NetworkStatus` (without it,
`Online` is quietly false).

## What the host answers

Window and surface, frames at the display's refreshes (and at the rate
`SetFrameRate` asks), touch in the XComponent's own `DispatchTouchEvent` —
ArkUI's `onTouch` never sees a surface's fingers — in pixels divided by the
scale to reach the DIPs Go lays out in, the keyboard as a see-through
`TextInput` over what Go draws, pages with and without a surface, alerts,
notifications, the clipboard, network status, secrets in the preferences,
the pickers, the share panel, haptics, keep-awake, the system's bars, and
the window's title.

Untried here: input methods' composition (`TextMark`/`TextUnmark` are
written; the harness that types commits text instead of composing), the tab
bar, the accessibility tree, the phone's navigation stack, and the covers of
placed pages.

## What a second window is

A window of a desktop app is a task of its own: focused apart, in the task
list, over or under the others. ArkUI's `createSubWindow` is none of that —
a
child of its window, always over it, in no task list — and an app that shows
two windows looks like an app that shows one over the other.

What is that window is an **instance of the ability** (`launchType:
multiton`): its own window, task entry, focus and place in the z-order, and
the same process, so the one Go runtime. An instance is started when Go
shows a window (`ShowWindow`), not when it makes it — an app makes windows
it never shows, and each would be an instance made for nothing.

Three things make an instance the window it should be, and each was wrong
first:

- The window id comes in the `want` and reaches the page through a
  `LocalStorage` the ability loads it with. `AppStorage` is the
  application's, so the id of the window that started another was read by
  the one that runs Go: the app's own window drew with the other's surface.
- Each XComponent is named after the window it draws (`mygo-<id>`), and the
  page binds it (`bind(id, onSurface, onTouch)`) with the callbacks of its
  own VM: a call into another VM's `napi_env` aborts it (`CheckThread`).
  Events of a window go to the instance that runs Go, queued and taken at
  its next frame — never waited for, since that instance is inside Go when
  it starts the other one, and two waiting for each other hold still.
- Go is entered from one frame at a time: an event that arrives while Go
  runs (a window of the app's is an instance of the same UI thread) waits
  for the next frame, or Go is entered twice on one stack and waits for
  itself.

## The files the app keeps

`os.UserConfigDir` finds nothing on a phone — the process has no home — so
an app's settings, its login and where playback was left were written
nowhere. The host's own directories (the `FilesDir` and `CacheDir` of
`AppInfo`, unused until now) stand in through `XDG_CONFIG_HOME` and
`XDG_CACHE_HOME`, and the app's name is its own, not `mygo`: the directory
it keeps its things in is named after it.

## Two things that hold a window still

- The app's standard error went to a pipe that the web view logs to as well
  — thousands of lines, on gestures — and a pipe that fills holds its
  writer: the UI thread, in `PAC_LogMessage::Flush`. The pipe is
  non-blocking and a megabyte, so a write that finds it full fails.
- A call of Go's reached the VM from whatever thread made it, and on the
  sound's thread that aborts it (`ecma_vm cannot run in multi-thread`, in
  `napi_create_typedarray`). Such a call is queued for the JS thread and
  waited for, two seconds at most.

## What the window tells Go

The size is the area the page draws in (`drawableRect`), not the window's
rect: content laid out for the latter begins under the title bar. A surface
that resizes is made anew (`SurfaceChanged` with a new size), as Android's
is, or the frame drawn at the old size is stretched over the window. A
theme the app chose is answered with `ThemeChanged`, which is what has it
draw again — and the wheel is not `Precise`, which is what has `ui` glide a
notch as a browser does.
