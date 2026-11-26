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
import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { PromptAction } from '@ohos.arkui.UIContext';
import { BusinessError } from '@ohos.base';
import { AppInfoReply, BatteryReply, CreateWindowCall, CreateWindowReply, Event, FirstFrameCall,
  LoadHTMLCall, LoadURLCall, MessageBoxCall, RequestFrameCall, ScreenReply, SetBackgroundCall, SetFrameRateCall, SetTextInputCall,
  ClipboardTextReply, EvalCall, GoBackCall, HapticCall, KeepAwakeCall, NetworkStatusReply,
  NotifyCall, OpenFilesCall, OpenURLReply, OpenURLCall, RemoveNotificationCall, SaveFileCall,
  SecretDeleteCall, SecretDeleteReply, SecretGetCall, SecretGetReply, SecretSetCall, SecretSetReply,
  SetClipboardTextCall, SetSystemBarsCall, GoForwardCall, ReloadCall, SetTitleCall, SetZoomCall, ShowWindowCall,
  StopLoadingCall, ThemeReply, dispatchCall } from './Wire';
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
  webVisible: boolean = false;
  webId: number = 0;
  private webSrc: string = '';
  private webHTML: string = '';
  private webBase: string = '';
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
  }

  firstFrame(c: FirstFrameCall): void {}

  // setTitle is the window's title, which the system's title bar shows.
  setTitle(c: SetTitleCall): void {
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
  webBegan(url: string): void {
    if (this.webId !== 0) {
      this.send(Event.navigationStarted(this.webId, url));
    }
  }

  webEnded(url: string, title: string): void {
    const w = this.webController;
    if (this.webId === 0) {
      return;
    }
    const back = w !== null && w.accessBackward();
    const forward = w !== null && w.accessForward();
    this.send(Event.navigationCommitted(this.webId, url));
    this.send(Event.pageState(this.webId, url, title, false, back, forward));
    this.send(Event.loadFinished(this.webId));
  }

  webFailed(url: string, code: number, description: string): void {
    if (this.webId !== 0) {
      this.send(Event.loadFailed(this.webId, url, code, description));
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
