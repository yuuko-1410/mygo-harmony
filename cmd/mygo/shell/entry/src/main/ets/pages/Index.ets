import native from 'libentry.so';
import displaySync from '@ohos.graphics.displaySync';
import display from '@ohos.display';
import window from '@ohos.window';
import webview from '@ohos.web.webview';
import util from '@ohos.util';
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

  aboutToAppear(): void {
    host.send = (buf: Uint8Array): void => {
      native.event(buf);
    };
    host.sendWaiting = (buf: Uint8Array): Uint8Array | null => {
      const reply = native.event(buf) as ArrayBuffer | undefined;
      if (reply === undefined) {
        return null;
      }
      return new Uint8Array(reply);
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
          this.getUIContext().getFocusController().requestFocus('mygoInput');
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

  // mimeOf is the media type of a page's URL, for the response Go's scheme
  // serves.
  private mimeOf(url: string): string {
    const dot = url.lastIndexOf('.');
    const end = url.indexOf('?', dot >= 0 ? dot : 0);
    const ext = dot >= 0 ? url.substring(dot + 1, end > 0 ? end : undefined).toLowerCase() : '';
    switch (ext) {
      case 'html':
      case 'htm':
        return 'text/html';
      case 'js':
        return 'text/javascript';
      case 'css':
        return 'text/css';
      case 'json':
        return 'application/json';
      case 'svg':
        return 'image/svg+xml';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'woff2':
        return 'font/woff2';
      default:
        return 'text/html';
    }
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
      console.info(`mygo: window ${rect.width}x${rect.height}, ` +
        `bars ${top},${left},${bottom},${right}, keyboard ${keyboard.bottomRect.height}`);
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
        XComponent({ id: 'mygo', type: XComponentType.SURFACE, libraryname: 'entry' })
          .width('100%')
          .height('100%')
          .onLoad(() => {
            if (started) {
              return;
            }
            started = true;
            native.start(
              (buf: Uint8Array): Uint8Array | null => host.call(buf),
              (handle: number, width: number, height: number, scale: number): void => {
                host.surface(handle, width, height, scale === 1 ? host.scale : scale);
              },
              (): void => {
                native.drain();
              },
              (phase: string, x: number, y: number): void => {
                host.touchPixels(phase, x, y);
              });
            // Not Event.ready: the backend posts that itself (postReady), and
            // a second one closes a channel twice.
            native.event(Event.active(true));
          })
      }

      // The page Go shows, in the host's web view.
      Web({ src: 'about:blank', controller: this.webController })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .opacity(this.webVisible ? 1 : 0)
        // The app's own schemes: Go serves them, and the answer comes back
        // in this call, which waits while the app's handler runs.
        .onInterceptRequest((event: OnInterceptRequestEvent) => {
          const url = event.request.getRequestUrl();
          if (!host.isAppScheme(url)) {
            return null;
          }
          const method = event.request.getRequestMethod();
          const header: string[] = [];
          for (const h of event.request.getRequestHeader()) {
            header.push(h.headerKey, h.headerValue);
          }
          const reply = host.schemeFetch(host.windowId, method, url, header, new Uint8Array(0), false);
          if (reply === null) {
            return null;
          }
          const response = new WebResourceResponse();
          response.setResponseCode(reply.status === 0 ? 500 : reply.status);
          response.setReasonMessage(reply.status === 0 ? 'Internal Server Error' : 'OK');
          response.setResponseMimeType(this.mimeOf(url));
          const mime = this.mimeOf(url);
          if (mime.startsWith('text/') || mime === 'application/json') {
            response.setResponseData(new util.TextDecoder('utf-8').decodeToString(reply.body));
            response.setResponseEncoding('utf-8');
          } else {
            response.setResponseData(reply.body.buffer as ArrayBuffer);
          }
          const headers: Header[] = [];
          for (let i = 0; i + 1 < reply.header.length; i += 2) {
            headers.push({ headerKey: reply.header[i], headerValue: reply.header[i + 1] });
          }
          response.setResponseHeader(headers);
          return response;
        })
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
        .position({ x: this.inputActive ? this.inputX : -2000, y: this.inputY })
        .width(this.inputActive && this.inputWidth > 0 ? this.inputWidth : 200)
        .height(this.inputActive && this.inputHeight > 0 ? this.inputHeight : 40)
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
  }
}
