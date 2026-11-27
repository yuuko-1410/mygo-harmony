import native from 'libentry.so';
import displaySync from '@ohos.graphics.displaySync';
import display from '@ohos.display';
import window from '@ohos.window';
import webview from '@ohos.web.webview';
import mediaquery from '@ohos.mediaquery';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { shared as host } from '../mygo/Shared';
import { Event } from '../mygo/Wire';

// ArkUI may build the page again, with a new struct: Go and its host are
// one, on the module, not on the struct that comes and goes.
let started: boolean = false;

@Entry
@Component
struct Index {
  private sync: displaySync.DisplaySync = displaySync.create();
  // Not `background`: that is ArkUI's own attribute, inherited by the
  // struct.
  @State windowColor: number = 0xff000000;
  // The web view Go makes: the page's Web component shows it.
  @State webVisible: boolean = false;
  private webController: webview.WebviewController = new webview.WebviewController();
  // The field the keyboard edits, which Go places: see Host.setTextInput.
  @State inputActive: boolean = false;
  @State inputX: number = 0;
  @State inputY: number = 0;
  @State inputWidth: number = 0;
  @State inputHeight: number = 0;
  @State inputText: string = '';
  private drawnAt: number = 0;

  // The window this instance draws: the app's own is 0, and a window of its
  // own carries its id in the storage its instance loaded the page with.
  private mygoWindow: number = 0;

  aboutToAppear(): void {
    this.mygoWindow = LocalStorage.getShared().get<number>('mygoWindow') ?? 0;
    host.pageWindow = this.mygoWindow;
    host.send = (buf: Uint8Array): void => {
      native.event(buf);
    };
    host.pump = (): void => {
      native.pump();
    };
    host.audioDone = (): void => {
      native.audioDone();
    };
    host.bindWindow = (id: number): void => {
      native.bind(id);
    };
    host.ask = (buf: Uint8Array): Uint8Array | null => {
      const reply: ArrayBuffer | undefined = native.event(buf) as ArrayBuffer | undefined;
      return reply === undefined ? null : new Uint8Array(reply);
    };
    const d = display.getDefaultDisplaySync();
    host.scale = d.densityPixels;
    host.prompt = this.getUIContext().getPromptAction();
    host.webController = this.webController;
    host.ctx = this.getUIContext().getHostContext();
    this.sync.setExpectedFrameRateRange({ expected: 60, min: 60, max: 120 });
    this.sync.on('frame', () => {
      host.tick();
      if (this.inputActive !== host.inputActive || this.inputX !== host.inputX ||
        this.inputY !== host.inputY || this.inputText !== host.inputText) {
        this.inputActive = host.inputActive;
        this.inputX = host.inputX;
        this.inputY = host.inputY;
        this.inputWidth = host.inputWidth;
        this.inputHeight = host.inputHeight;
        this.inputText = host.inputText;
        if (this.inputActive) {
          // The field may not be in the tree yet, or not yet shown: taking
          // the focus of one that is not throws, and takes the app with it.
          try {
            this.getUIContext().getFocusController().requestFocus('mygoInput');
          } catch (e) {
            console.info(`mygo: focus: ${e}`);
          }
        }
      }
      // Go draws at the rate it asks for while frames follow each other.
      if (host.fps > 0 && host.fps !== this.drawnAt) {
        this.drawnAt = host.fps;
        this.sync.setExpectedFrameRateRange({ expected: host.fps, min: 60, max: 120 });
      }
      // The window's background is Go's, and it changes as it paints.
      if (this.windowColor !== host.background) {
        this.windowColor = host.background;
      }
      if (this.webVisible !== host.webVisible) {
        this.webVisible = host.webVisible;
      }
    });
    this.sync.start();
    // The system's colors, which the app follows while it follows them.
    const darkMode = mediaquery.matchMediaSync('(dark-mode: true)');
    host.systemDark = darkMode.matches;
    darkMode.on('change', (r: mediaquery.MediaQueryResult) => {
      host.systemDark = r.matches;
      host.systemThemeChanged();
    });
    // A heartbeat: a hang leaves the last call it was in, in the log.
    setInterval(() => {
      host.heartbeat();
    }, 1000);
    window.getLastWindow(this.getUIContext().getHostContext()).then((w: window.Window) => {
      host.sysWindow = w;
      this.measure(w);
      // The bars, the cutout and the keyboard come and go.
      w.on('avoidAreaChange', () => {
        this.measure(w);
      });
      w.on('windowSizeChange', () => {
        this.measure(w);
      });
    }).catch((e: Error) => {
      console.error(`mygo: no window to measure: ${e.message}`);
    });
  }

  // measure tells the host what the system covers, in pixels.
  private measure(w: window.Window): void {
    try {
      const rect = w.getWindowProperties().windowRect;
      const bars = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const keyboard = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
      const top = Math.max(bars.topRect.height, cutout.topRect.height);
      const left = Math.max(bars.leftRect.width, cutout.leftRect.width);
      const right = Math.max(bars.rightRect.width, cutout.rightRect.width);
      const bottom = Math.max(bars.bottomRect.height, keyboard.bottomRect.height);
      // The window's pixels over its units, both from the window itself,
      // which ArkUI converts: a maximized window and a restored one are
      // measured the same way, where the page's own area, arriving in a
      // callback of its own, is a size behind.
      const ui = this.getUIContext();
      const width = ui.px2vp(rect.width);
      host.scale = width > 0 ? rect.width / width : host.scale;
      console.info(`mygo: window ${rect.width}x${rect.height} px, scale ${host.scale}`);
      // Pixels: the host turns them into the units Go lays out in, by the
      // scale, which is the window's own and not the display's.
      host.sizeChanged(rect.width, rect.height,
        [top, left, bottom, right, keyboard.bottomRect.height]);
    } catch (e) {
      console.error(`mygo: measure: ${e}`);
    }
  }

  aboutToDisappear(): void {
    this.sync.stop();
  }

  build() {
    Column() {
      // The surface is its own layer, over ArkUI's: while a page shows, it
      // goes, so that the page is not under it. Its fingers come through
      // the module too: a surface's touch is the app's, and ArkUI's onTouch
      // does not see it.
      if (!this.webVisible) {
        XComponent({ id: this.mygoWindow === 0 ? 'mygo' : `mygo-${this.mygoWindow}`,
          type: XComponentType.SURFACE, libraryname: 'entry' })
          .width('100%')
          .height('100%')
          .onLoad(() => {
            if (this.mygoWindow !== 0) {
              // A window of its own draws with this page's component, and
              // its callbacks live in this instance's VM: Go runs in the
              // instance that started it.
              native.bind(this.mygoWindow,
                (id: number, handle: number, width: number, height: number, scale: number): void => {
                  host.surface(id, handle, width, height, scale === 1 ? host.scale : scale);
                },
                (id: number, phase: string, kind: string, pointer: number, x: number, y: number): void => {
                  host.touchPixels(id, phase, kind, pointer, x, y);
                });
              native.event(Event.active(true));
              return;
            }
            if (started) {
              return;
            }
            started = true;
            native.start(
              (buf: Uint8Array): Uint8Array | null => host.call(buf),
              (id: number, handle: number, width: number, height: number, scale: number): void => {
                host.surface(id, handle, width, height, scale === 1 ? host.scale : scale);
              },
              (): void => {
                native.drain();
              },
              (id: number, phase: string, kind: string, pointer: number, x: number, y: number): void => {
                host.touchPixels(id, phase, kind, pointer, x, y);
              });
            // The page's component draws for the app's own window, which Go
            // names when it makes it (createWindow binds it then).
            native.bind(0);
            // Not Event.ready: the backend posts that itself (postReady), and
            // a second one closes a channel twice.
            native.event(Event.active(true));
          })
          // A wheel or a trackpad over the surface: ArkUI's own axes, which a
          // surface's touch does not carry.
          .onAxisEvent((event: AxisEvent) => {
            if (event.action !== AxisAction.UPDATE) {
              return;
            }
            // The wheel's place is in the window's pixels, as a finger's is.
            const windowId = host.windowForPage(this.mygoWindow);
            const scale = host.scaleOf.get(windowId) ?? host.scale;
            host.wheelAt(windowId, (event.displayX ?? 0) / (scale > 0 ? scale : 1),
              (event.displayY ?? 0) / (scale > 0 ? scale : 1),
              event.axisHorizontal ?? 0, event.axisVertical ?? 0);
          })
      }

      // The page Go shows, in the host's web view.
      Web({ src: 'about:blank', controller: this.webController })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .opacity(this.webVisible ? 1 : 0)
        // A web view of nothing still takes the touches over it, and the
        // surface under it, which is the app's, never sees them go down.
        .hitTestBehavior(this.webVisible ? HitTestMode.Default : HitTestMode.None)
        .onPageBegin((event: OnPageBeginEvent) => {
          host.webBegan(host.webId, event.url);
        })
        .onPageEnd((event: OnPageEndEvent) => {
          host.webEnded(host.webId, event.url, event.url);
        })
        .onErrorReceive((event: OnErrorReceiveEvent) => {
          if (event.error) {
            host.webFailed(host.webId, event.request.getRequestUrl(), event.error.getErrorCode(),
              event.error.getErrorInfo());
          }
        })

      // The field the keyboard edits, over what Go draws there: it stays in
      // the tree, off to the side while there is no text to edit.
      TextInput({ text: this.inputText })
        .id('mygoInput')
        .type(InputType.Normal)
        // Out of the way and a point big while Go edits no text: a field
        // that is invisible still takes the touches over it, and the app
        // under it would not see them.
        .position({ x: this.inputActive ? this.inputX : -4000, y: this.inputActive ? this.inputY : -4000 })
        .width(this.inputActive && this.inputWidth > 0 ? this.inputWidth : 1)
        .height(this.inputActive && this.inputHeight > 0 ? this.inputHeight : 1)

        .hitTestBehavior(this.inputActive ? HitTestMode.Default : HitTestMode.None)
        .backgroundColor('#00000000')
        // The app draws the text and the caret: the field only takes the
        // keys, and shows where it is being edited.
        .fontColor('#00000000')
        .caretColor('#00000000')
        .onChange((value: string, preview?: PreviewText) => {
          // A composing input method marks its text; the rest is the edit.
          if (preview !== undefined && preview.value.length > 0) {
            // ArkUI's value leaves the composing text out: the field would
            // hold it where the preview says.
            const pv = preview.value;
            const full = value.includes(pv) ? value :
              value.substring(0, preview.offset) + pv + value.substring(preview.offset);
            host.compose(full, pv, preview.offset);
          } else {
            host.replaceText(value);
          }
        })
        .onSubmit(() => {
          // Go's name for the key the field's return is.
          host.command('newline');
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.windowColor)
    // Escape is a PC's back: the page in front, or the window that shows
    // it, goes.
    .onKeyEvent((e: KeyEvent) => {
      if (e.type === KeyType.Down && e.keyCode === KeyCode.KEYCODE_ESCAPE) {
        host.back();
        return true;
      }
      return false;
    })
  }
}
