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
import notificationManager from '@ohos.notificationManager';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import fileUri from '@ohos.file.fileuri';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
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
  StopLoadingCall, ThemeReply, WireReader, dispatchCall } from './Wire';
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
  private wanted: boolean = false;
  // The surface, which may come before the window Go asks for.
  private handle: number = 0;
  private width: number = 0;
  private height: number = 0;

  createWindow(c: CreateWindowCall): CreateWindowReply {
    if (!c.surface) {
      // A page, not a surface: the page's Web component shows it.
      this.webId = c.id;
      this.webVisible = true;
    }
    this.windowId = c.id;
    const r = new CreateWindowReply();
    r.error = '';
    r.layer = 0;
    if (this.handle !== 0) {
      this.windowSize();
    }
    return r;
  }

  showWindow(c: ShowWindowCall): void {
    this.windowId = c.id;
    const sub = this.subs.get(c.id);
    if (sub !== undefined) {
      sub.showWindow().catch((e: BusinessError) => {
        console.error(`mygo: show ${c.id}: ${e.message}`);
      });
    }
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

  // readClipboard asks the system for the clipboard, a few frames apart.
  private readClipboard(): void {
    this.clipFrames++;
    if (this.clipFrames % 20 !== 0) {
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
      // A child window's bar is off by default: no title, no drag, no close
      // button, and the system will not give it the focus.
      sub.setWindowDecorVisible(true);
      sub.setWindowTitle(`mygo ${id}`);
      sub.setWindowTitleMoveEnabled(true);
      sub.setWindowFocusable(true);
      sub.setWindowDecorHeight(40);
      sub.setWindowLimits({ maxWidth: 10000, maxHeight: 10000, minWidth: 120, minHeight: 80 });
      const place = this.pendingPlaces.get(id);
      if (place !== undefined) {
        this.pendingPlaces.delete(id);
        sub.moveWindowTo(place[0], place[1]).catch(() => {});
        sub.resize(place[2], place[3]).catch(() => {});
      }
      sub.loadContent('pages/Embedded', this.local(id)).then(() => {
        sub.showWindow().catch((e: BusinessError) => {
          console.error(`mygo: show ${id}: ${e.message}`);
        });
      }).catch((e: BusinessError) => {
        console.error(`mygo: content ${id}: ${e.message}`);
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
  setAppearance(c: SetAppearanceCall): void {
    this.appearance = c.source;
    if (c.source === 'dark') {
      this.dark = true;
    } else if (c.source === 'light') {
      this.dark = false;
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
  schemeRespond(c: SchemeRespondCall): void {
    this.schemeAnswer(c.req, c.status, c.header, new Uint8Array(0));
  }

  schemeData(c: SchemeDataCall): void {
    this.schemeBody(c.req, c.data);
  }

  schemeFinish(c: SchemeFinishCall): void {
  }

  schemeFail(c: SchemeFailCall): void {
    this.schemeAnswer(c.req, 404, [], new Uint8Array(0));
  }

  private schemeAnswer(req: number, status: number, header: string[], body: Uint8Array): void {
    // The interception is synchronous for ArkUI's web engine: the host asks
    // Go before the request, and this is where the answer lands.
    this.schemeStatus.set(req, status);
    if (body.length > 0) {
      this.schemeBodies.set(req, body);
    }
  }

  private schemeBody(req: number, data: Uint8Array): void {
    const seen = this.schemeBodies.get(req);
    if (seen === undefined) {
      this.schemeBodies.set(req, data);
      return;
    }
    const joined = new Uint8Array(seen.length + data.length);
    joined.set(seen, 0);
    joined.set(data, seen.length);
    this.schemeBodies.set(req, joined);
  }

  private schemeStatus: Map<number, number> = new Map();
  private schemeBodies: Map<number, Uint8Array> = new Map();

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
        renderer.start();
      }).catch((e: BusinessError) => {
        console.error(`mygo: audio: ${e.message}`);
      });
    } catch (e) {
      r.error = `${e}`;
    }
    return r;
  }

  audioWrite(c: AudioWriteCall): AudioWriteReply {
    const r = new AudioWriteReply();
    if (this.renderer === null) {
      return r;  // not made yet: the samples are dropped, not waited for
    }
    this.renderer.write(c.samples.buffer.slice(0) as ArrayBuffer).catch((e: BusinessError) => {
      console.error(`mygo: audio: ${e.message}`);
    });
    return r;
  }

  audioClose(): AudioCloseReply {
    const r = new AudioCloseReply();
    const renderer = this.renderer;
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
  }

  appInfo(): AppInfoReply {
    const r = new AppInfoReply();
    r.name = 'mygo';
    r.identifier = 'dev.mygo.app';
    r.version = '0.0.1';
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
  surface(handle: number, width: number, height: number, scale: number): void {
    this.scale = scale;
    this.handle = handle;
    this.width = width;
    this.height = height;
    if (this.windowId !== 0) {
      this.windowSize();
    }
  }

  // windowSize tells Go the window's size in DIPs, its scale and its
  // insets, then where to draw: it draws nothing while it knows no size.
  private windowSize(): void {
    if (this.windowId === 0 || this.handle === 0) {
      return;
    }
    const scale = this.scale > 0 ? this.scale : 1;
    this.send(Event.surfaceChanged(this.windowId, this.handle, this.width, this.height, scale, 60));
    this.send(Event.resized(this.windowId, this.width / scale, this.height / scale, scale,
      this.insetTop / scale, this.insetLeft / scale, this.insetBottom / scale, this.insetRight / scale,
      this.keyboard / scale));
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
  touchPixels(phase: string, x: number, y: number): void {
    const scale = this.scale > 0 ? this.scale : 1;
    this.touch(x / scale, y / scale, phase);
  }

  touch(x: number, y: number, phase: string): void {
    if (this.windowId !== 0) {
      this.send(Event.touch(this.windowId, 0, phase, 'touch', x, y, 1, 0, 0));
    }
  }

  // tick runs at the display's refreshes: a frame Go asked for, or none.
  tick(): void {
    this.readClipboard();
    if (this.wanted && this.windowId !== 0) {
      this.wanted = false;
      this.send(Event.frame(this.windowId));
    }
  }

  // call runs one call of Go, on the JS thread.
  call(buf: Uint8Array): Uint8Array | null {
    try {
      return dispatchCall(this, buf);
    } catch (e) {
      // A call the host answers badly must not take the app with it.
      console.error(`mygo: a call failed: ${e}`);
      return null;
    }
  }
}
