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
