// The ArkTS host: the calls Go makes of it, and the events it sends Go.
// It starts from HostStubs, which does nothing for the calls this host has
// no use for yet, and adds what a window needs: the surface ArkUI made,
// frames, and touch.

import promptAction from '@ohos.promptAction';
import webview from '@ohos.web.webview';
import vibrator from '@ohos.vibrator';
import pasteboard from '@ohos.pasteboard';
import connection from '@ohos.net.connection';
import preferences from '@ohos.data.preferences';
import util from '@ohos.util';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import image from '@ohos.multimedia.image';
import audio from '@ohos.multimedia.audio';
import bundleManager from '@ohos.bundle.bundleManager';
import notificationManager from '@ohos.notificationManager';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import fileUri from '@ohos.file.fileuri';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import display from '@ohos.display';
import { PromptAction } from '@ohos.arkui.UIContext';
import { BusinessError } from '@ohos.base';
import { AppInfoReply, BatteryReply, CreateWindowCall, CreateWindowReply, Event, FirstFrameCall,
  LoadHTMLCall, LoadURLCall, MessageBoxCall, RequestFrameCall, ScreenReply, SetBackgroundCall, SetFrameRateCall, SetTextInputCall,
  ClipboardTextReply, EvalCall, GoBackCall, HapticCall, KeepAwakeCall, NetworkStatusReply,
  AccessibilityChangedCall, AddTabCall, AnnounceCall, AudioCloseReply, AudioOpenCall, AudioOpenReply,
  AudioWriteCall, AudioWriteReply, CallAsyncCall, CapturePageCall, ClipboardImageReply, CloseTabsCall,
  CreateTabsCall, DrawTextCall, DrawTextReply, LogCall, MeasureTextCall, MeasureTextReply,
  MeasureTextRunCall, MeasureTextRunReply, PluginCallCall, PopWindowCall, PopupMenuCall,
  PushWindowCall, RegisterFontCall, RegisterFontReply, SchemeDataCall, SchemeFailCall,
  SchemeFinishCall, SchemeRespondCall, SelectTabCall, SetAppearanceCall, SetBackAvailableCall,
  SetBarItemsCall, SetClipboardImageCall, SetCursorCall, SetOrientationsCall, SetStackCall,
  SetStackReply, SetTabBadgeCall, SetUserAgentCall, SetUserScriptsCall, ShowMagnifierCall,
  ShowMenuCall, ShowTabsCall, StackShownCall, TextAdvancesCall, TextAdvancesReply, TextMetricsCall,
  TextMetricsReply, TimeZoneReply, UserAgentCall, UserAgentReply,
  CloseWindowCall, FocusCall, HideMagnifierCall, HideMenuCall, HideWindowCall, NotifyCall, OpenFilesCall, ShareCall, ShareFileCall, PlaceViewsCall, OpenURLReply, OpenURLCall, RemoveNotificationCall, SaveFileCall,
  SecretDeleteCall, SecretDeleteReply, SecretGetCall, SecretGetReply, SecretSetCall, SecretSetReply,
  SetClipboardTextCall, SetSystemBarsCall, GoForwardCall, ReloadCall, SetTitleCall, SetZoomCall, ShowWindowCall,
  StopLoadingCall, ThemeReply, WireReader, BackPressedReply, dispatchCall } from './Wire';
import { HostStubs } from './HostStubs';

export class Host extends HostStubs {
  // The window Go made last, whose surface the XComponent draws.
  windowId: number = 0;
  dark: boolean = true;
  scale: number = 1;
  // What the system's bars, a cutout and the keyboard cover, in pixels, and
  // the window's size in the same: the insets Go lays content inside.
  insetTop: number = 0;
  insetLeft: number = 0;
  insetBottom: number = 0;
  insetRight: number = 0;
  keyboard: number = 0;
  // The field the keyboard edits: Go says where it is and what it holds,
  // and the page puts a see-through TextInput there, which takes the keys.
  inputActive: boolean = false;
  inputX: number = 0;
  inputY: number = 0;
  inputWidth: number = 0;
  inputHeight: number = 0;
  inputText: string = '';
  private inputId: number = 0;
  // Whether an input method is composing: its text is marked, not yet the
  // document's.
  private composing: boolean = false;
  // What the document Go holds was, when the composing started.
  private markBase: number = 0;
  // The web view Go made, if any: the page's Web component, which the host
  // drives. Its id is Go's window.
  webController: webview.WebviewController | null = null;
  // The pages of the surface's children, by Go's window id, and what each
  // was told to load before it existed.
  private webChildren: Map<number, webview.WebviewController> = new Map();
  private webSources: Map<number, string> = new Map();
  webVisible: boolean = false;
  // The app's own schemes, which Go serves: the page asks the host for them.
  schemes: string[] = [];
  webId: number = 0;
  private webSrc: string = '';
  private webHTML: string = '';
  private webBase: string = '';
  // The windows the surface's pages show in, and the places they wait for.
  private subs: Map<number, window.Window> = new Map();
  private pendingPlaces: Map<number, number[]> = new Map();
  private creating: Set<number> = new Set();
  // Where Go last asked a child window to be: a place asked again is not
  // applied, so a window moved by hand stays where it was put.
  private placedAt: Map<number, number[]> = new Map();
  // The ids Go last said the surface shows.
  placed: number[] = [];
  // The page's window, for what the system does to it: bars, the screen
  // staying on.
  sysWindow: window.Window | null = null;
  // The system's dialogs, which the page hands over: the host answers Go
  // with what the user chose.
  prompt: PromptAction | null = null;
  // The window's background, as 0xAARRGGBB, and the rate frames come at.
  background: number = 0xff000000;
  fps: number = 0;
  // Sends an event to Go: the page's native.event.
  send: (buf: Uint8Array) => void = (buf: Uint8Array) => {};
  // bindWindow has the component the page draws with draw for window id.
  bindWindow: (id: number) => void = (id: number): void => {};
  // pump takes the events the other windows queued, which wait for the
  // instance that runs Go.
  pump: () => void = (): void => {};
  // audioDone is the renderer having taken the buffer Go wrote: its writer
  // waits for this, which is what paces the player.
  audioDone: () => void = (): void => {};
  // ask sends an event Go answers, and reads its reply.
  ask: (buf: Uint8Array) => Uint8Array | null = (buf: Uint8Array): Uint8Array | null => null;
  // mainWindow is the window Go made first: the app's own, as Android's is
  // the Activity's.
  mainWindowId: number = 0;
  // Where the app's own files live, which the windows share.
  private filesDir: string = getContext().filesDir;
  // The window this page draws: 0 for the app's own.
  pageWindow: number = 0;
  private wanted: boolean = false;
  // The windows that asked for a frame, each for itself.
  private wantedWindows: Set<number> = new Set();
  private ticks: number = 0;
  // The surface, which may come before the window Go asks for.
  private handle: number = 0;
  private width: number = 0;
  private height: number = 0;

  createWindow(c: CreateWindowCall): CreateWindowReply {
    this.schemes = c.schemes;
    if (!c.surface) {
      // A page, not a surface: the page's Web component shows it.
      this.webId = c.id;
      this.webVisible = true;
    }
    this.windowId = c.id;
    if (this.mainWindowId === 0) {
      this.mainWindowId = c.id;
    } else if (c.surface) {
      // A window of the app's is an instance of its own, made when Go shows
      // it: an app makes windows it does not show, and each would be one.
      this.surfaceWindows.add(c.id);
      this.pendingWindows.add(c.id);
    }
    const r = new CreateWindowReply();
    r.error = '';
    r.layer = 0;
    // The first window draws on the surface until Go shows another: a
    // window made behind the one that shows draws nothing, and taking the
    // surface for it leaves the one that shows with none.
    if (c.id === this.mainWindowId) {
      // The app's own window draws with the page's component, which was
      // made before Go named the window.
      this.bindWindow(c.id);
      if (this.handle !== 0) {
        this.windowSize();
      }
    }
    return r;
  }

  showWindow(c: ShowWindowCall): void {
    this.windowId = c.id;
    // The window that shows draws: it takes the surface, and the one that
    // had it lets go (windowSize).
    if (this.handle !== 0) {
      this.windowSize();
    }
    if (this.surfaceWindows.has(c.id)) {
      const made = !this.pendingWindows.has(c.id) && this.startedWindows.has(c.id);
      this.pendingWindows.delete(c.id);
      if (made) {
        // The window is there: its instance is a VM of its own, so it is
        // asked, through a file of the app's, to come to the front.
        this.requestRaise(c.id);
        return;
      }
      this.startInstance(c.id);
      return;
    }
    const sub = this.subs.get(c.id);
    if (sub === undefined) {
      return;
    }
    sub.showWindow().then(() => {
      this.decorate(c.id, sub);
    }).catch((e: BusinessError) => {
      console.error(`mygo: show ${c.id}: ${e.message}`);
    });
  }

  // startInstance starts the app again, as the window it draws: an instance
  // of the ability is a window of its own, with a task entry and a focus.
  private startedWindows: Set<number> = new Set();

  private raisePath(id: number): string {
    return `${this.filesDir}/raise-${id}`;
  }

  // requestRaise asks the instance of a window that exists to come to the
  // front: instances are VMs of their own, and the only thing they share is
  // the app's files.
  private requestRaise(id: number): void {
    try {
      const f = fs.openSync(this.raisePath(id), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, `${Date.now()}`);
      fs.closeSync(f);
    } catch (e) {
      console.error(`mygo: raise ${id}: ${e}`);
    }
  }

  // checkRaise is a window's instance finding that it was asked for.
  private checkRaise(id: number): boolean {
    const path = this.raisePath(id);
    try {
      if (!fs.accessSync(path)) {
        return false;
      }
      fs.unlinkSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  private startInstance(id: number): void {
    const ctx = this.ctx as common.UIAbilityContext;
    if (ctx === null) {
      console.error(`mygo: no ability for window ${id}`);
      return;
    }
    // Once per window, whatever the system makes of the key: a window of the
    // app's that is there is not made again.
    if (this.startedWindows.has(id)) {
      ctx.startAbility({
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
        parameters: {
          mygoWindow: id,
          instanceKey: `mygo-${id}`,
          'ohos.ability.params.instanceKey': `mygo-${id}`,
        },
      }).catch(() => {});
      return;
    }
    this.startedWindows.add(id);
    ctx.startAbility({
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: ctx.abilityInfo.name,
      // The key the system keeps one instance of the app for this window:
      // the doc's name, and the one the ability manager reads.
      parameters: {
        mygoWindow: id,
        instanceKey: `mygo-${id}`,
        'ohos.ability.params.instanceKey': `mygo-${id}`,
      },
    }).catch((e: BusinessError) => {
      console.error(`mygo: window ${id}: ${e.code} ${e.message}`);
    });
  }

  // The windows whose decor is set, which is once they show: before that
  // their state is not one the system sets it in (1300002), and the call
  // throws and takes the app with it.
  private decorated: Set<number> = new Set();

  private decorate(id: number, sub: window.Window): void {
    if (this.decorated.has(id)) {
      return;
    }
    this.decorated.add(id);
    const step = (fn: () => void): void => {
      try {
        fn();
      } catch (e) {
        console.info(`mygo: window ${id}: ${e}`);
      }
    };
    step(() => { sub.setSubWindowModal(false); });
    step(() => { sub.setWindowDecorVisible(true); });
    step(() => { sub.setWindowTitle(`mygo ${id}`); });
    step(() => { sub.setWindowTitleMoveEnabled(true); });
    step(() => { sub.setWindowFocusable(true); });
    step(() => {
      sub.setWindowLimits({ maxWidth: 10000, maxHeight: 10000, minWidth: 120, minHeight: 80 });
    });
  }

  // hideWindow and closeWindow are a child window's page going away, and the
  // window it showed in going with it.
  hideWindow(c: HideWindowCall): void {
    const sub = this.subs.get(c.id);
    if (sub !== undefined) {
      sub.minimize().catch((e: BusinessError) => {
        console.error(`mygo: hide ${c.id}: ${e.message}`);
      });
    }
  }

  closeWindow(c: CloseWindowCall): void {
    this.surfaceWindows.delete(c.id);
    // The window that closed took the input with it: the app's own window
    // draws with its component still, and says so again.
    if (this.mainWindowId !== 0) {
      this.windowId = this.mainWindowId;
      this.bindWindow(this.mainWindowId);
    }
    const sub = this.subs.get(c.id);
    if (sub === undefined) {
      return;
    }
    this.subs.delete(c.id);
    this.placedAt.delete(c.id);
    this.webChildren.delete(c.id);
    this.webSources.delete(c.id);
    this.placed = this.placed.filter((id: number): boolean => id !== c.id);
    sub.destroyWindow().then(() => {
      console.info(`mygo: closed ${c.id}`);
    }).catch((e: BusinessError) => {
      console.error(`mygo: close ${c.id}: ${e.message}`);
    });
  }

  // focus brings a child window's page to the front.
  focus(c: FocusCall): void {
    const sub = this.subs.get(c.id);
    if (sub !== undefined) {
      sub.showWindow().catch((e: BusinessError) => {
        console.error(`mygo: focus ${c.id}: ${e.message}`);
      });
    }
  }

  firstFrame(c: FirstFrameCall): void {}

  // setTitle is the window's title, which the system's title bar shows.
  setTitle(c: SetTitleCall): void {
    const sub = this.subs.get(c.id);
    if (sub !== undefined) {
      sub.setWindowTitle(c.title).catch((e: BusinessError) => {
        console.error(`mygo: title ${c.id}: ${e.message}`);
      });
      return;
    }
    const w = this.sysWindow;
    if (w === null) {
      return;
    }
    w.setWindowTitle(c.title).catch((e: BusinessError) => {
      console.error(`mygo: title: ${e.message}`);
    });
  }

  // loadURL and loadHTML are what the page shows; the rest drive it.
  loadURL(c: LoadURLCall): void {
    const child = this.webChildren.get(c.id);
    if (child !== undefined) {
      this.webSources.set(c.id, c.url);
      child.loadUrl(c.url);
      return;
    }
    this.webSources.set(c.id, c.url);
    if (c.id !== this.webId) {
      return;
    }
    this.webSrc = c.url;
    this.webHTML = '';
    this.webVisible = true;
    this.applyWeb();
  }

  loadHTML(c: LoadHTMLCall): void {
    if (c.id !== this.webId) {
      return;
    }
    this.webHTML = c.html;
    this.webBase = c.baseURL;
    this.webSrc = '';
    this.webVisible = true;
    this.applyWeb();
  }

  reload(c: ReloadCall): void {
    if (c.id === this.webId && this.webController !== null) {
      this.webController.refresh();
    }
  }

  stopLoading(c: StopLoadingCall): void {
    if (c.id === this.webId && this.webController !== null) {
      this.webController.stop();
    }
  }

  goBack(c: GoBackCall): void {
    const w = this.webController;
    if (c.id === this.webId && w !== null && w.accessBackward()) {
      w.backward();
    }
  }

  goForward(c: GoForwardCall): void {
    const w = this.webController;
    if (c.id === this.webId && w !== null && w.accessForward()) {
      w.forward();
    }
  }

  eval(c: EvalCall): void {
    if (c.id === this.webId && this.webController !== null) {
      this.webController.runJavaScript(c.js);
    }
  }

  setZoom(c: SetZoomCall): void {
    if (c.id === this.webId && this.webController !== null) {
      this.webController.zoom(c.factor);
    }
  }

  // registerWeb takes a child window's controller as its page appears, and
  // loads what Go asked for before it did.
  registerWeb(id: number, controller: webview.WebviewController): void {
    this.webChildren.set(id, controller);
  }

  unregisterWeb(id: number): void {
    this.webChildren.delete(id);
  }

  // webSource is what a child window was told to load.
  webSource(id: number): string {
    const url = this.webSources.get(id);
    return url !== undefined ? url : '';
  }

  // applyWeb shows what Go asked for, once the page has its controller.
  private applyWeb(): void {
    const w = this.webController;
    if (w === null) {
      return;
    }
    if (this.webSrc !== '') {
      w.loadUrl(this.webSrc);
    } else if (this.webHTML !== '') {
      w.loadData(this.webHTML, 'text/html', 'UTF-8', this.webBase, '');
    }
  }

  // webBegan, webEnded and webFailed are the page's own reports, which Go
  // hears as its events.
  webBegan(id: number, url: string): void {
    if (id !== 0) {
      this.send(Event.navigationStarted(id, url));
    }
  }

  webEnded(id: number, url: string, title: string): void {
    const w = this.webChildren.get(id) ?? this.webController;
    if (id === 0) {
      return;
    }
    const back = w !== null && w !== undefined && w.accessBackward();
    const forward = w !== null && w !== undefined && w.accessForward();
    this.send(Event.navigationCommitted(id, url));
    this.send(Event.pageState(id, url, title, false, back, forward));
    this.send(Event.loadFinished(id));
  }

  webFailed(id: number, url: string, code: number, description: string): void {
    if (id !== 0) {
      this.send(Event.loadFailed(id, url, code, description));
    }
  }

  // setBackground paints the window the colour Go asked for.
  setBackground(c: SetBackgroundCall): void {
    this.background = c.color;
  }

  // setFrameRate is how often Go draws while frames follow each other: the
  // display's own when it asks for none.
  setFrameRate(c: SetFrameRateCall): void {
    this.fps = c.fps;
  }

  // setTextInput is Go asking for the keyboard, or telling it to go.
  setTextInput(c: SetTextInputCall): void {
    if (!c.active) {
      this.inputId = 0;
      this.inputActive = false;
      return;
    }
    console.info(`mygo: field ${c.id} doc=${c.document} text=${c.text} sel=${c.selStart},${c.selEnd} base=${c.base}`);
    this.inputId = c.id;
    this.inputActive = true;
    this.inputX = c.x;
    this.inputY = c.y;
    this.inputWidth = c.width;
    this.inputHeight = c.height;
    this.inputText = c.text;
  }

  // compose is an input method's text as it is typed: marked, not yet the
  // document's. Text is what the field holds, of which preview is the part
  // being composed, starting at offset.
  compose(text: string, preview: string, offset: number): void {
    if (this.inputId === 0) {
      return;
    }
    if (!this.composing) {
      this.composing = true;
      this.markBase = this.inputText.length;
    }
    this.inputText = text;
    console.info(`mygo: compose text=${text} preview=${preview} offset=${offset}`);
    this.send(Event.textMark(this.inputId, true, 0, this.markBase, text, offset, offset + preview.length));
  }

  // replaceText is the user's edit: what the field holds now, which Go puts
  // in place of the document it gave the host, or of the text it marked
  // while it was composing.
  replaceText(text: string): void {
    if (this.inputId === 0 || text === this.inputText) {
      return;
    }
    console.info(`mygo: replace text=${text} composing=${this.composing}`);
    const composing = this.composing;
    const base = composing ? this.markBase : this.inputText.length;
    this.composing = false;
    this.inputText = text;
    if (composing) {
      // In place of the marked text, which Go holds.
      this.send(Event.textReplace(this.inputId, false, 0, 0, text));
    } else {
      this.send(Event.textReplace(this.inputId, true, 0, base, text));
    }
  }

  // command is a key the field takes as an action, as Enter or Delete.
  command(name: string): void {
    if (this.inputId !== 0) {
      this.send(Event.textCommand(this.inputId, name));
    }
  }

  // messageBox shows the system's alert and answers with the button the
  // user took, as Event.messageBoxResult.
  messageBox(c: MessageBoxCall): void {
    const texts: string[] = c.buttons.length > 0 ? c.buttons : ['OK'];
    const buttons: promptAction.Button[] = [];
    for (const text of texts) {
      buttons.push({ text: text, color: '#007aff' });
    }
    const message = c.detail.length > 0 ? `${c.message}\n\n${c.detail}` : c.message;
    const options: promptAction.ShowDialogOptions = { title: c.title, message: message, buttons: buttons };
    if (this.prompt === null) {
      this.send(Event.messageBoxResult(c.req, c.cancelID));
      return;
    }
    this.prompt.showDialog(options).then((r: promptAction.ShowDialogSuccessResponse) => {
      this.send(Event.messageBoxResult(c.req, r.index));
    }).catch((e: BusinessError) => {
      // Dismissed: the cancel button, as a phone's alert does.
      this.send(Event.messageBoxResult(c.req, c.cancelID));
    });
  }

  // keepAwake keeps the screen on while the app shows.
  keepAwake(c: KeepAwakeCall): void {
    const w = this.sysWindow;
    if (w === null) {
      return;
    }
    w.setWindowKeepScreenOn(c.on).catch((e: BusinessError) => {
      console.error(`mygo: keep awake: ${e.message}`);
    });
  }

  // setSystemBars sets the icons of the system's bars and hides them.
  setSystemBars(c: SetSystemBarsCall): void {
    const w = this.sysWindow;
    if (w === null) {
      return;
    }
    if (c.hidden) {
      w.setWindowSystemBarEnable([]).catch((e: BusinessError) => {
        console.error(`mygo: hide the bars: ${e.message}`);
      });
      return;
    }
    const dark = c.style === 'light';
    w.setWindowSystemBarProperties({
      statusBarContentColor: dark ? '#000000' : '#ffffff',
      navigationBarContentColor: dark ? '#000000' : '#ffffff',
    }).catch((e: BusinessError) => {
      console.error(`mygo: the bars' colours: ${e.message}`);
    });
  }

  // haptic is the system's tap, or its buzz for an error.
  haptic(c: HapticCall): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 20 }, { id: 0, usage: 'touch' });
    } catch (e) {
      console.error(`mygo: haptic: ${e}`);
    }
  }

  // The clipboard's text is kept here: Go asks for it in the middle of a
  // call, which cannot wait, so the system is read between frames and its
  // answer lands here.
  private clipText: string = '';
  private clipOK: boolean = false;
  private clipFrames: number = 0;

  // clipboardText is what the system's clipboard held as of this frame.
  clipboardText(): ClipboardTextReply {
    const r = new ClipboardTextReply();
    r.text = this.clipText;
    r.ok = this.clipOK;
    return r;
  }

  // setClipboardText puts text in the system's clipboard.
  setClipboardText(c: SetClipboardTextCall): void {
    this.clipText = c.text;
    this.clipOK = c.text.length > 0;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, c.text);
      pasteboard.getSystemPasteboard().setData(data).catch((e: BusinessError) => {
        console.error(`mygo: clipboard set: ${e.message}`);
      });
    } catch (e) {
      console.error(`mygo: clipboard: ${e}`);
    }
  }

  // readClipboard asks the system for the clipboard, a few frames apart,
  // and only while a field could take it: the pasteboard refuses a reader
  // without the permission it asks for, and a refused read is a talk with
  // the system that comes to nothing.
  private readClipboard(): void {
    this.clipFrames++;
    if (!this.inputActive || this.clipFrames % 20 !== 0) {
      return;
    }
    pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
      const text = data.getPrimaryText();
      if (text !== undefined && text !== this.clipText) {
        this.clipText = text;
        this.clipOK = text.length > 0;
      }
    }).catch((e: BusinessError) => {
      this.clipOK = false;
    });
  }

  // networkStatus is whether the system is online, and whether it is
  // metered.
  networkStatus(): NetworkStatusReply {
    const r = new NetworkStatusReply();
    try {
      const net = connection.getDefaultNetSync();
      r.online = net !== undefined && net.netId !== 0;
      const caps = connection.getNetCapabilitiesSync(net);
      if (caps !== undefined) {
        const bc = caps.bearerTypes;
        r.metered = bc !== undefined && bc.length > 0 && bc[0] === connection.NetBearType.BEARER_CELLULAR;
      }
    } catch (e) {
      r.online = false;
    }
    return r;
  }

  // The app's secrets, kept in the system's preferences: base64 text, so
  // that bytes of any kind survive.
  // The app's own context, which the page hands over: the storage and the
  // pickers need it.
  ctx: common.Context | undefined = undefined;
  private secrets: preferences.Preferences | null = null;
  private readonly b64: util.Base64Helper = new util.Base64Helper();

  private secretsFile(): preferences.Preferences | null {
    if (this.secrets !== null) {
      return this.secrets;
    }
    const ctx = this.ctx;
    if (ctx === undefined) {
      return null;
    }
    try {
      this.secrets = preferences.getPreferencesSync(ctx, { name: 'mygo-secrets' });
    } catch (e) {
      console.error(`mygo: secrets: ${e}`);
      return null;
    }
    return this.secrets;
  }

  private secretKey(c: SecretGetCall | SecretSetCall | SecretDeleteCall): string {
    return `${c.service}\u0000${c.account}`;
  }

  secretGet(c: SecretGetCall): SecretGetReply {
    const r = new SecretGetReply();
    const store = this.secretsFile();
    if (store === null) {
      r.error = 'no storage';
      return r;
    }
    const text = store.getSync(this.secretKey(c), '') as string;
    if (text.length === 0) {
      return r;
    }
    try {
      r.value = this.b64.decodeSync(text);
      r.found = true;
    } catch (e) {
      r.error = `${e}`;
    }
    return r;
  }

  secretSet(c: SecretSetCall): SecretSetReply {
    const r = new SecretSetReply();
    const store = this.secretsFile();
    if (store === null) {
      r.error = 'no storage';
      return r;
    }
    try {
      store.putSync(this.secretKey(c), this.b64.encodeToStringSync(c.value));
      store.flush();
    } catch (e) {
      r.error = `${e}`;
    }
    return r;
  }

  secretDelete(c: SecretDeleteCall): SecretDeleteReply {
    const r = new SecretDeleteReply();
    const store = this.secretsFile();
    if (store === null) {
      r.error = 'no storage';
      return r;
    }
    try {
      store.deleteSync(this.secretKey(c));
      store.flush();
    } catch (e) {
      r.error = `${e}`;
    }
    return r;
  }

  // openFiles shows the system's picker and copies what was picked where
  // the app may read it: FilesResult answers with the copies.
  openFiles(c: OpenFilesCall): void {
    const ctx = this.ctx;
    if (ctx === undefined) {
      this.send(Event.filesResult(c.req, [], 'no context'));
      return;
    }
    const p = new picker.DocumentViewPicker(ctx);
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: c.multiple ? 20 : 1,
    };
    if (c.directories) {
      options.selectMode = picker.DocumentSelectMode.FOLDER;
    }
    if (c.extensions.length > 0) {
      const filters: string[] = [];
      for (const ext of c.extensions) {
        filters.push(ext.startsWith('.') ? ext : `.${ext}`);
      }
      options.fileSuffixFilters = filters;
    }
    p.select(options).then((uris: string[]) => {
      const paths: string[] = [];
      for (const uri of uris) {
        const path = c.directories ? uri : this.copyInto(uri);
        if (path !== '') {
          paths.push(path);
        }
      }
      this.send(Event.filesResult(c.req, paths, ''));
    }).catch((e: BusinessError) => {
      // Dismissed is not an error, as a phone's picker says.
      const message = e.code === 13900042 ? '' : `${e.message}`;
      this.send(Event.filesResult(c.req, [], message));
    });
  }

  // saveFile shows the picker of where to keep a copy of a file.
  saveFile(c: SaveFileCall): void {
    const ctx = this.ctx;
    if (ctx === undefined) {
      this.send(Event.filesResult(c.req, [], 'no context'));
      return;
    }
    const p = new picker.DocumentViewPicker(ctx);
    const name = c.name.length > 0 ? c.name : 'mygo.txt';
    const options: picker.DocumentSaveOptions = { newFileNames: [name] };
    p.save(options).then((uris: string[]) => {
      if (uris.length === 0) {
        this.send(Event.filesResult(c.req, [], ''));
        return;
      }
      try {
        const dst = fs.openSync(uris[0], fs.OpenMode.READ_WRITE);
        fs.copyFileSync(c.path, dst.fd);
        fs.closeSync(dst);
      } catch (e) {
        this.send(Event.filesResult(c.req, [], `${e}`));
        return;
      }
      this.send(Event.filesResult(c.req, [uris[0]], ''));
    }).catch((e: BusinessError) => {
      this.send(Event.filesResult(c.req, [], `${e.message}`));
    });
  }

  // copyInto copies a picked document into the app's cache, where its own
  // files are: the picker's uri is not one of those.
  private copyInto(uri: string): string {
    const ctx = this.ctx;
    if (ctx === undefined) {
      return '';
    }
    try {
      const dir = `${ctx.cacheDir}/mygo-picked`;
      fs.mkdirSync(dir, true);
      const cut = uri.lastIndexOf('/');
      const name = cut >= 0 ? uri.substring(cut + 1) : 'file';
      const dest = `${dir}/${name}`;
      const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(src.fd, dest);
      fs.closeSync(src);
      return dest;
    } catch (e) {
      console.error(`mygo: copy ${uri}: ${e}`);
      return '';
    }
  }

  // openURL opens a URL in the app the system has for it.
  openURL(c: OpenURLCall): OpenURLReply {
    const r = new OpenURLReply();
    const ctx = this.ctx;
    if (ctx === undefined) {
      return r;
    }
    try {
      (ctx as common.UIAbilityContext).startAbility({
        action: 'ohos.want.action.viewData',
        uri: c.url,
      }).then(() => {
        r.ok = true;
      }).catch((e: BusinessError) => {
        console.error(`mygo: open ${c.url}: ${e.message}`);
      });
      r.ok = true;
    } catch (e) {
      console.error(`mygo: open ${c.url}: ${e}`);
    }
    return r;
  }

  // notify puts a notification in the system's list, and answers once the
  // system has it.
  notify(c: NotifyCall): void {
    const ctx = this.ctx;
    if (ctx === undefined) {
      return;
    }
    const req: notificationManager.NotificationRequest = {
      id: this.notificationId(c.notificationID),
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: c.title.length > 0 ? c.title : c.subtitle,
          text: c.body,
          additionalText: c.subtitle,
        },
      },
      isUnremovable: false,
      tapDismissed: true,
    };
    if (c.group.length > 0) {
      req.groupName = c.group;
    }
    notificationManager.publish(req).then(() => {
      this.send(Event.notifyDone(c.req, ''));
    }).catch((e: BusinessError) => {
      if (e.code === 1600004 && ctx !== undefined) {
        // The app's notifications are off: the system asks the user, and
        // this one goes once they agree.
        notificationManager.requestEnableNotification(ctx as common.UIAbilityContext).then(() => {
          notificationManager.publish(req).then(() => {
            this.send(Event.notifyDone(c.req, ''));
          }).catch((again: BusinessError) => {
            this.send(Event.notifyDone(c.req, again.message));
          });
        }).catch((no: BusinessError) => {
          this.send(Event.notifyDone(c.req, no.message));
        });
        return;
      }
      this.send(Event.notifyDone(c.req, e.message));
    });
  }

  // removeNotification takes one away, by the id Go gave it.
  removeNotification(c: RemoveNotificationCall): void {
    notificationManager.cancel(this.notificationId(c.notificationID)).catch((e: BusinessError) => {
      console.error(`mygo: notification ${c.notificationID}: ${e.message}`);
    });
  }

  removeAllNotifications(): void {
    notificationManager.cancelAll().catch((e: BusinessError) => {
      console.error(`mygo: notifications: ${e.message}`);
    });
  }

  // notificationId is the system's number for Go's string: a hash of it,
  // kept so that a removal finds what its notification made.
  private notificationIds: Map<string, number> = new Map();
  private nextNotificationId: number = 1;

  private notificationId(id: string): number {
    const known = this.notificationIds.get(id);
    if (known !== undefined) {
      return known;
    }
    const n = this.nextNotificationId++;
    this.notificationIds.set(id, n);
    return n;
  }

  // placeViews is where the surface shows the pages it holds: a window of
  // their own, at the place, over the surface — which is a layer above
  // ArkUI and would hide them.
  placeViews(c: PlaceViewsCall): void {
    const r = new WireReader(c.places);
    const shown: number[] = [];
    while (!r.done()) {
      const id = r.int();
      const fx = r.float();
      const fy = r.float();
      const fw = r.float();
      const fh = r.float();
      const cx = r.float();
      const cy = r.float();
      const cw = r.float();
      const ch = r.float();
      const covers = r.int();
      for (let i = 0; i < covers * 4; i++) {
        r.float();
      }
      if (id === 0) {
        continue;
      }
      shown.push(id);
      // The place is in DIPs of the surface: the subwindow takes the
      // screen's pixels.
      const scale = this.scale > 0 ? this.scale : 1;
      console.info(`mygo: place ${id} at ${fx},${fy} ${fw}x${fh}`);
      this.place(id, Math.round(fx * scale), Math.round(fy * scale),
        Math.round(Math.min(fw, cw) * scale), Math.round(Math.min(fh, ch) * scale));
    }
    this.placed = shown;
  }

  // place puts a child window's page at x, y, w, h of the screen.
  private place(id: number, x: number, y: number, w: number, h: number): void {
    // One window, as a phone's. A window of its own would be one of the
    // system's: no bar of its own, no place in the task switcher, no focus
    // of its own — see NOTES.md. So the page shows in this window, over the
    // surface, which goes while it does.
    this.webId = id;
    this.webVisible = true;
    const src = this.webSources.get(id);
    if (src !== undefined && src !== this.webSrc) {
      this.webSrc = src;
      this.webHTML = '';
      this.applyWeb();
    }
  }

  // makeSub makes the window a page of the surface shows in, once.
  private makeSub(id: number): void {
    const stage = AppStorage.get<window.WindowStage>('windowStage');
    if (stage === undefined) {
      console.error('mygo: no window stage for a child window');
      this.creating.delete(id);
      return;
    }
    stage.createSubWindow(`mygo-${id}`).then((sub: window.Window) => {
      this.subs.set(id, sub);
      this.creating.delete(id);
      const place = this.pendingPlaces.get(id);
      if (place !== undefined) {
        this.pendingPlaces.delete(id);
        sub.moveWindowTo(place[0], place[1]).catch(() => {});
        sub.resize(place[2], place[3]).catch(() => {});
      } else {
        // A sub-window comes out the size of the screen, over everything: a
        // window of the app's takes a part of it, in the middle, as a
        // window of a desktop app does.
        const d = display.getDefaultDisplaySync();
        const w = Math.max(320, Math.floor(d.width * 0.55));
        const h = Math.max(240, Math.floor(d.height * 0.7));
        sub.resize(w, h).catch(() => {});
        sub.moveWindowTo(Math.floor((d.width - w) / 2), Math.floor((d.height - h) / 2)).catch(() => {});
      }
      const page = this.surfaceWindows.has(id) ? 'pages/Window' : 'pages/Embedded';
      // Loaded, not shown: Go shows the windows it shows (ShowWindow), and
      // one made behind another draws nothing until it does.
      return sub.loadContent(page, this.local(id)).then(() => {
        this.decorated.delete(id);
      });
    }).catch((e: BusinessError) => {
      this.creating.delete(id);
      console.error(`mygo: subwindow ${id}: ${e.message}`);
    });
  }

  // local hands the page its window's id, which a subwindow's page cannot
  // otherwise know.
  private local(id: number): LocalStorage {
    const storage = new LocalStorage();
    storage.setOrCreate('id', id);
    return storage;
  }

  // shareFile shows the system's share sheet for a file: the place to
  // save it, or send it on.
  shareFile(c: ShareFileCall): void {
    const single = new ShareCall();
    single.req = 0;
    single.text = '';
    single.url = '';
    single.paths = [c.path];
    single.x = 0;
    single.y = 0;
    this.share(single);
  }

  // share shows the system's share panel for text, a link and files.
  share(c: ShareCall): void {
    const ctx = this.ctx as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    const records: systemShare.SharedRecord[] = [];
    if (c.text.length > 0) {
      records.push({
        utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
        content: c.url.length > 0 ? `${c.text}\n${c.url}` : c.text,
      });
    }
    for (const path of c.paths) {
      records.push({
        utd: uniformTypeDescriptor.UniformDataType.FILE,
        uri: fileUri.getUriFromPath(path),
      });
    }
    if (records.length === 0) {
      return;
    }
    try {
      const data = new systemShare.SharedData(records[0]);
      for (let i = 1; i < records.length; i++) {
        data.addRecord(records[i]);
      }
      const controller = new systemShare.ShareController(data);
      controller.show(ctx, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE,
      });
    } catch (e) {
      console.error(`mygo: share: ${e}`);
    }
  }

  // mimeOf is the media type of a file, by its name.
  private mimeOf(path: string): string {
    const dot = path.lastIndexOf('.');
    const ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'pdf':
        return 'application/pdf';
      case 'json':
        return 'application/json';
      case 'txt':
      case 'md':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }


  // ---- The rest of the protocol

  // The system's own answers, where the platform has them.
  private appearance: string = 'system';
  private watching: boolean = false;
  private clipImage: Uint8Array = new Uint8Array(0);
  private userAgentValue: string = '';
  private userScripts: string[] = [];
  private cursor: string = '';
  private focusNode: number = 0;
  private backAvailable: boolean = false;
  private renderer: audio.AudioRenderer | null = null;

  timeZone(): TimeZoneReply {
    const r = new TimeZoneReply();
    r.id = new Intl.DateTimeFormat().resolvedOptions().timeZone;
    return r;
  }

  // setAppearance is what the app asks of the window, which the theme this
  // host reports follows: "dark", "light" or the system's.
  // setAppearance is the app choosing light, dark, or the system's: the
  // host takes it, and tells Go the theme changed so that it draws again
  // with it — a choice nobody tells Go of changes nothing on the screen.
  setAppearance(c: SetAppearanceCall): void {
    const was = this.dark;
    this.appearance = c.source;
    if (c.source === 'dark') {
      this.dark = true;
    } else if (c.source === 'light') {
      this.dark = false;
    } else {
      this.dark = this.systemDark;
    }
    if (this.dark !== was || c.source === 'system') {
      this.send(Event.themeChanged());
    }
  }

  // systemDark is whether the system is dark now, which the page keeps: a
  // media query needs the UI its context is in.
  systemDark: boolean = false;

  // systemThemeChanged is the system's colors changing: the app follows
  // them while it follows the system.
  systemThemeChanged(): void {
    if (this.appearance !== 'system') {
      return;
    }
    const was = this.dark;
    this.dark = this.systemDark;
    if (this.dark !== was) {
      this.send(Event.themeChanged());
    }
  }

  log(c: LogCall): void {
    if (c.error) {
      hilog.error(0xD002, 'Go', '%{public}s', c.line);
    } else {
      hilog.info(0xD002, 'Go', '%{public}s', c.line);
    }
  }

  watchNetwork(): void {
    if (this.watching) {
      return;
    }
    this.watching = true;
    try {
      const watcher = connection.createNetConnection();
      watcher.on('netAvailable', () => {
        this.reportNetwork();
      });
      watcher.on('netLost', () => {
        this.reportNetwork();
      });
      watcher.on('netCapabilitiesChange', () => {
        this.reportNetwork();
      });
      watcher.register(() => {
        this.reportNetwork();
      });
    } catch (e) {
      console.error(`mygo: watch network: ${e}`);
    }
  }

  private reportNetwork(): void {
    const status = this.networkStatus();
    this.send(Event.networkChanged(status.online, status.metered));
  }

  // The picture in the clipboard, kept as PNG: Go asks in the middle of a
  // call, and the system's pasteboard is asynchronous.
  clipboardImage(): ClipboardImageReply {
    const r = new ClipboardImageReply();
    r.png = this.clipImage;
    return r;
  }

  setClipboardImage(c: SetClipboardImageCall): void {
    this.clipImage = c.png;
    if (c.png.length === 0) {
      return;
    }
    try {
      const source = image.createImageSource(c.png.buffer.slice(0) as ArrayBuffer);
      source.createPixelMap().then((pm: image.PixelMap) => {
        const data = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pm);
        pasteboard.getSystemPasteboard().setData(data).catch((e: BusinessError) => {
          console.error(`mygo: clipboard image: ${e.message}`);
        });
      }).catch((e: BusinessError) => {
        console.error(`mygo: clipboard image: ${e.message}`);
      });
    } catch (e) {
      console.error(`mygo: clipboard image: ${e}`);
    }
  }

  setUserAgent(c: SetUserAgentCall): void {
    this.userAgentValue = c.userAgent;
  }

  userAgent(c: UserAgentCall): UserAgentReply {
    const r = new UserAgentReply();
    r.userAgent = this.userAgentValue.length > 0 ? this.userAgentValue : 'mygo';
    return r;
  }

  setUserScripts(c: SetUserScriptsCall): void {
    this.userScripts = c.scripts;
  }

  // callAsync runs Go's body as an async function's, and answers what it
  // returned.
  callAsync(c: CallAsyncCall): void {
    const w = this.webController;
    if (w === null) {
      this.send(Event.asyncResult(c.req, '', 'no page'));
      return;
    }
    w.runJavaScript(c.body).then((result: string) => {
      this.send(Event.asyncResult(c.req, result, ''));
    }).catch((e: BusinessError) => {
      this.send(Event.asyncResult(c.req, '', e.message));
    });
  }

  // capturePage: the web engine's own snapshot is not reachable from the
  // controller this host has, so the answer says so rather than hanging.
  capturePage(c: CapturePageCall): void {
    this.send(Event.captured(c.req, new Uint8Array(0), 'no snapshot from this host'));
  }

  // The app's schemes reach the web engine's requests, which the page
  // intercepts; the answers Go gives go to that request.
  // A scheme's answer arrives in parts, which a page needs in one call:
  // ArkUI's web engine asks in the same call it must be given one, so the
  // parts cannot be handed over yet — see NOTES.md.
  schemeRespond(c: SchemeRespondCall): void {
  }

  schemeData(c: SchemeDataCall): void {
  }

  schemeFinish(c: SchemeFinishCall): void {
  }

  schemeFail(c: SchemeFailCall): void {
  }

  // The tabs, the stack and the bars of a phone are drawn by the host, and
  // this host draws none: a surface is a layer above ArkUI's, so a bar of
  // ArkUI's cannot be over it. Go draws its own, and these answer so that
  // nothing waits.
  createTabs(c: CreateTabsCall): void {
  }

  addTab(c: AddTabCall): void {
  }

  showTabs(c: ShowTabsCall): void {
  }

  selectTab(c: SelectTabCall): void {
    this.send(Event.tabSelected(c.id, c.index));
  }

  setTabBadge(c: SetTabBadgeCall): void {
  }

  closeTabs(c: CloseTabsCall): void {
  }

  // A page that a surface pushes is a window of its own, and this host
  // shows one window: the stack is kept as Go asks, and the pages Go makes
  // show in this window's web view as they are placed.
  pushWindow(c: PushWindowCall): void {
  }

  popWindow(c: PopWindowCall): void {
    this.send(Event.stackPopped(c.id, 0));
  }

  setStack(c: SetStackCall): SetStackReply {
    const r = new SetStackReply();
    return r;
  }

  stackShown(c: StackShownCall): void {
  }

  setBarItems(c: SetBarItemsCall): void {
  }

  popupMenu(c: PopupMenuCall): void {
    // No menu of the system's can be over a surface: Go hears that none was
    // chosen, at once, rather than waiting for a menu that never comes.
    this.send(Event.menuPicked(c.req, 0));
  }

  pluginCall(c: PluginCallCall): void {
    this.send(Event.pluginResult(c.req, '', 'no plugin host', 'unsupported'));
  }

  audioOpen(c: AudioOpenCall): AudioOpenReply {
    const r = new AudioOpenReply();
    this.audioRate = c.rate;
    try {
      const options: audio.AudioRendererOptions = {
        streamInfo: {
          samplingRate: c.rate,
          channels: audio.AudioChannel.CHANNEL_2,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_F32LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
        },
        rendererInfo: {
          usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
          rendererFlags: 0,
        },
      };
      audio.createAudioRenderer(options).then((renderer: audio.AudioRenderer) => {
        this.renderer = renderer;
        renderer.start().then(() => {
          this.flushAudio();
        }).catch((e: BusinessError) => {
          console.error(`mygo: audio start: ${e.message}`);
        });
      }).catch((e: BusinessError) => {
        console.error(`mygo: audio open: ${e.message}`);
      });
    } catch (e) {
      r.error = `${e}`;
    }
    return r;
  }

  // The renderer comes a moment after the call, and Go writes as it calls:
  // the samples wait here until it does.
  private audioRate: number = 44100;
  private audioPending: Uint8Array[] = [];

  audioWrite(c: AudioWriteCall): AudioWriteReply {
    const r = new AudioWriteReply();
    const samples = c.samples;
    if (this.renderer === null) {
      // Half a second at most, then the oldest goes: a player that writes
      // faster than the output opens is not to grow without bound.
      this.audioPending.push(samples);
      const limit = Math.max(1, Math.floor(this.audioRate / 60));
      while (this.audioPending.length > limit) {
        this.audioPending.shift();
      }
      // Go's writer waits for the output to take each buffer: a buffer that
      // waits for the renderer's birth is taken by the open, so the wait
      // ends here, once per write — a write no one answers holds the
      // player's thread for its whole second, and the player skips.
      this.audioDone();
      return r;
    }
    this.writeAudio(samples);
    return r;
  }

  private flushAudio(): void {
    const pending = this.audioPending;
    this.audioPending = [];
    for (const samples of pending) {
      this.writeAudio(samples);
    }
  }

  // The renderer takes a write a time: Go writes as its player runs, and
  // writes that pile onto one another are the renderer's buffers made
  // wreckage of. Each waits for the one before it.
  private audioQueue: Promise<void> = Promise.resolve();

  private writeAudio(samples: Uint8Array): void {
    const renderer = this.renderer;
    if (renderer === null || samples.length === 0) {
      this.audioDone();
      return;
    }
    const buf = samples.buffer.slice(0) as ArrayBuffer;
    this.audioQueue = this.audioQueue.then(() => {
      return renderer.write(buf).then(() => {
        this.audioDone();
      }).catch((e: BusinessError) => {
        console.error(`mygo: audio write: ${e.message}`);
        this.audioDone();
      });
    });
  }

  audioClose(): AudioCloseReply {
    const r = new AudioCloseReply();
    const renderer = this.renderer;
    this.audioPending = [];
    if (renderer !== null) {
      this.renderer = null;
      renderer.stop().then(() => {
        renderer.release();
      }).catch(() => {
        renderer.release();
      });
    }
    return r;
  }

  // The app draws its own text, with libnative_drawing: the host's text is
  // a font of half a size a letter, which Go's own engine never asks for.
  textMetrics(c: TextMetricsCall): TextMetricsReply {
    const r = new TextMetricsReply();
    r.ascent = c.size * 0.8;
    r.descent = c.size * 0.2;
    r.xHeight = c.size * 0.5;
    r.underlinePosition = c.size * 0.1;
    r.underlineThickness = 1;
    r.strikePosition = c.size * 0.3;
    return r;
  }

  measureText(c: MeasureTextCall): MeasureTextReply {
    const r = new MeasureTextReply();
    const widths: number[] = [];
    for (const text of c.texts) {
      widths.push(text.length * c.size * 0.5);
    }
    r.widths = widths;
    return r;
  }

  textAdvances(c: TextAdvancesCall): TextAdvancesReply {
    const r = new TextAdvancesReply();
    const advances: number[] = [];
    for (let i = 0; i < c.text.length; i++) {
      advances.push(c.size * 0.5);
    }
    r.advances = advances;
    return r;
  }

  measureTextRun(c: MeasureTextRunCall): MeasureTextRunReply {
    const r = new MeasureTextRunReply();
    r.width = Math.max(0, c.end - c.start) * c.size * 0.5;
    return r;
  }

  drawText(c: DrawTextCall): DrawTextReply {
    const r = new DrawTextReply();
    r.left = 0;
    r.top = 0;
    r.width = 0;
    r.height = 0;
    r.color = false;
    r.pixels = new Uint8Array(0);
    return r;
  }

  registerFont(c: RegisterFontCall): RegisterFontReply {
    const r = new RegisterFontReply();
    return r;
  }

  // The system's overlays of a window, which a surface's window has none of
  // here: kept, so that the app's state is not lost, and answered.
  setCursor(c: SetCursorCall): void {
    this.cursor = c.cursor;
  }

  accessibilityChanged(c: AccessibilityChangedCall): void {
    this.focusNode = c.focus;
  }

  announce(c: AnnounceCall): void {
    hilog.info(0xD002, 'Go', 'announce: %{public}s', c.text);
  }

  showMenu(c: ShowMenuCall): void {
  }

  hideMenu(c: HideMenuCall): void {
  }

  setOrientations(c: SetOrientationsCall): void {
    // A 2in1 turns as its user turns it, and the platform's lock is the
    // app's to ask of its ability: the mask is kept, and nothing turns.
    this.orientations = c.mask;
  }

  private orientations: number = 0;

  setBackAvailable(c: SetBackAvailableCall): void {
    this.backAvailable = c.on;
  }

  showMagnifier(c: ShowMagnifierCall): void {
  }

  hideMagnifier(c: HideMagnifierCall): void {
  }

  // requestFrame notes that Go has something to draw: the display's next
  // refresh brings it a Frame event.
  requestFrame(c: RequestFrameCall): void {
    this.wanted = true;
    this.wantedWindows.add(this.windowForPage(c.id === 0 ? 0 : c.id));
  }

  appInfo(): AppInfoReply {
    const r = new AppInfoReply();
    r.name = 'mygo';
    r.identifier = 'dev.mygo.app';
    r.version = '0.0.1';
    // The app's own: what it is called is where it keeps what it keeps.
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      r.name = info.name;
      r.identifier = info.name;
      r.version = info.versionName;
    } catch (e) {
      console.error(`mygo: app info: ${e}`);
    }
    r.filesDir = getContext().filesDir;
    r.cacheDir = getContext().cacheDir;
    r.tempDir = getContext().tempDir;
    r.documentsDir = getContext().filesDir;
    r.system = 'OpenHarmony';
    return r;
  }

  // The system reports the theme; this host reads it when it starts.
  theme(): ThemeReply {
    const r = new ThemeReply();
    r.dark = this.dark;
    r.accent = 0xff007aff;
    r.textScale = 1;
    return r;
  }

  screen(): ScreenReply {
    const r = new ScreenReply();
    r.width = 360;
    r.height = 780;
    r.scale = this.scale;
    return r;
  }

  battery(): BatteryReply {
    const r = new BatteryReply();
    r.level = 1;
    r.charging = true;
    return r;
  }

  // surface tells Go where to draw: the window ArkUI made, in pixels.
  // surface is a window's own native window, which ArkUI made for the
  // component that draws it: each window of the app's has one.
  surface(id: number, handle: number, width: number, height: number, scale: number): void {
    if (id === 0) {
      // Not yet bound to a window: the page binds it as Go makes one.
      this.scale = scale;
      this.handle = handle;
      this.width = width;
      this.height = height;
      return;
    }
    if (this.surfaceOf.get(id) !== handle) {
      this.surfaceOf.set(id, handle);
    }
    if (this.scaleOf.get(id) !== scale) {
      this.scaleOf.set(id, scale);
    }
    this.sizeOf.set(id, [width, height]);
    this.handleOf.set(id, handle);
    if (id === this.windowId) {
      this.scale = scale;
      this.handle = handle;
      this.width = width;
      this.height = height;
    }
    this.windowSizeFor(id);
  }

  // The surface each window draws into, its size and the pixels one of its
  // units is, which a finger's place is measured by.
  surfaceOf: Map<number, number> = new Map();
  // The surface ArkUI made for each window, which the window's page knows.
  handleOf: Map<number, number> = new Map();
  scaleOf: Map<number, number> = new Map();
  sizeOf: Map<number, [number, number]> = new Map();
  // The windows of the app's that draw with a surface of their own.
  private surfaceWindows: Set<number> = new Set();
  private pendingWindows: Set<number> = new Set();

  private isSurfaceWindow(id: number): boolean {
    return this.surfaceWindows.has(id);
  }

  // windowSize tells Go the window's size in DIPs, its scale and its
  // insets, then where to draw: it draws nothing while it knows no size.
  // back is the system's back, as Android's: the window in front's content
  // takes it, and a window that does not take it goes, a window of Go's
  // own being closed as the system closes an Activity's. A PC has no back
  // button: Escape is its own, and the page's.
  back(): void {
    const id = this.windowId;
    if (id === 0) {
      return;
    }
    let handled = false;
    const reply = this.ask(Event.backPressed(id));
    if (reply !== null && reply.length > 0) {
      handled = BackPressedReply.decode(new WireReader(reply)).handled;
    }
    if (!handled && id !== this.mainWindowId) {
      this.send(Event.popped(id));
    }
  }

  private windowSize(): void {
    this.windowSizeFor(this.windowId);
  }

  // windowSizeFor tells Go one window's size in DIPs, its scale and its
  // insets: each window has a surface, a size and a scale of its own.
  private windowSizeFor(id: number): void {
    const handle = this.handleOf.get(id) ?? (id === this.windowId ? this.handle : 0);
    const size = this.sizeOf.get(id) ?? [this.width, this.height];
    const scale = this.scaleOf.get(id) ?? this.scale;
    const s = scale > 0 ? scale : 1;
    if (id === 0 || handle === 0 || size[0] <= 0) {
      return;
    }
    this.send(Event.surfaceChanged(id, handle, size[0], size[1], s, 60));
    this.send(Event.resized(id, size[0] / s, size[1] / s, s,
      this.insetTop / s, this.insetLeft / s, this.insetBottom / s, this.insetRight / s,
      this.keyboard / s));
  }

  // sizeChanged is the page telling what the system covers, in pixels.
  sizeChanged(width: number, height: number, insets: number[]): void {
    if (width > 0) {
      this.width = width;
    }
    if (height > 0) {
      this.height = height;
    }
    if (insets.length >= 5) {
      this.insetTop = insets[0];
      this.insetLeft = insets[1];
      this.insetBottom = insets[2];
      this.insetRight = insets[3];
      this.keyboard = insets[4];
    }
    this.windowSize();
  }

  // touchPixels is a finger of the surface, in its pixels: Go lays out in
  // DIPs.
  touchPixels(id: number, phase: string, x: number, y: number): void {
    const scale = this.scaleOf.get(id) ?? this.scale;
    const s = scale > 0 ? scale : 1;
    this.touch(id, x / s, y / s, phase);
  }

  touch(id: number, x: number, y: number, phase: string): void {
    if (id !== 0) {
      // Seconds, as Go measures a tap's double and a finger's speed.
      const now = Date.now() / 1000;
      this.send(Event.touch(id, 0, phase, 'touch', x, y, 1, 0, now));
    }
  }

  // scroll is a wheel or a trackpad over the surface, at a place of the
  // window: what the pointer is over is what scrolls.
  scroll(dx: number, dy: number): void {
    this.scrollAt(0, 0, dx, dy);
  }

  scrollAt(x: number, y: number, dx: number, dy: number): void {
    this.scrollOf(this.windowId, x, y, dx, dy);
  }

  private scrollOf(id: number, x: number, y: number, dx: number, dy: number): void {
    if (id !== 0) {
      // Not precise: a wheel's notches glide, which ui gives them as a
      // browser does — a little physics of its own — while a trackpad's
      // small moves follow the fingers as they come.
      this.send(Event.scroll(id, x, y, dx, dy, false, 'changed'));
    }
  }

  // wheel is ArkUI's axes, in the window's own units.
  wheel(x: number, y: number, dx: number, dy: number): void {
    this.scrollAt(x, y, dx, dy);
  }

  // windowForPage is the window a page draws: the app's own window is the one
  // Go made first, and a window of its own says so itself.
  windowForPage(pageId: number): number {
    return pageId !== 0 ? pageId : this.mainWindowId;
  }

  // wheelAt is a wheel over a window of the app's, which is not the one in
  // front of the others.
  wheelAt(id: number, x: number, y: number, dx: number, dy: number): void {
    this.scrollOf(id, x, y, dx, dy);
  }

  // tick runs at the display's refreshes: a frame Go asked for, or none.
  tick(): void {
    // A window of its own comes to the front when asked for.
    this.ticks++;
    if (this.pageWindow !== 0 && this.ticks % 15 === 0 && this.checkRaise(this.pageWindow)) {
      const win = this.sysWindow;
      if (win !== null) {
        win.showWindow().catch((e: BusinessError) => {
          console.error(`mygo: raise: ${e.message}`);
        });
      }
    }
    // The windows of other instances queue their events: they run here,
    // where Go runs, at this frame.
    this.pump();
    this.readClipboard();
    if (this.wantedWindows.size > 0) {
      const ids = Array.from(this.wantedWindows);
      this.wantedWindows.clear();
      for (const id of ids) {
        if (id !== 0) {
          this.send(Event.frame(id));
        }
      }
    }
  }

  // The call a hang would be in: the heartbeat names it while it runs.
  private inCall: boolean = false;
  private callOp: number = -1;
  private callAt: number = 0;

  // heartbeat says which call has not come back, once a second.
  heartbeat(): void {
    if (!this.inCall) {
      return;
    }
    const waited = Date.now() - this.callAt;
    if (waited > 900) {
      console.info(`mygo: stuck in call ${this.callOp} for ${waited}ms`);
    }
  }

  // call runs one call of Go, on the JS thread.
  call(buf: Uint8Array): Uint8Array | null {
    const op = buf.length > 0 ? buf[0] : -1;
    if (op !== 72) { // not the frame Go asks for at every refresh
      console.info(`mygo: call ${op} of ${buf.length} bytes`);
    }
    this.inCall = true;
    this.callOp = op;
    this.callAt = Date.now();
    try {
      return dispatchCall(this, buf);
    } catch (e) {
      // A call the host answers badly must not take the app with it.
      console.error(`mygo: a call failed: ${e}`);
      return null;
    } finally {
      this.inCall = false;
    }
  }
}
