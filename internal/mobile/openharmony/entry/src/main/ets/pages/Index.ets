import native from 'libentry.so';
import displaySync from '@ohos.graphics.displaySync';
import display from '@ohos.display';
import window from '@ohos.window';
import { Host } from '../mygo/Host';
import { Event } from '../mygo/Wire';

// ArkUI may build the page again, with a new struct: Go and its host are
// one, on the module, not on the struct that comes and goes.
let started: boolean = false;
const host: Host = new Host();

@Entry
@Component
struct Index {
  private sync: displaySync.DisplaySync = displaySync.create();
  // Not `background`: that is ArkUI's own attribute, inherited by the
  // struct.
  @State windowColor: number = 0xff000000;
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
    const d = display.getDefaultDisplaySync();
    host.scale = d.densityPixels;
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
    });
    this.sync.start();
    window.getLastWindow(this.getUIContext().getHostContext()).then((w: window.Window) => {
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
      // The window ArkUI makes for Go, whose surface the module reports.
      // Its fingers come through the module too: a surface's touch is the
      // app's, and ArkUI's onTouch does not see it.
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

      // The field the keyboard edits, over what Go draws there: it stays in
      // the tree, off to the side while there is no text to edit.
      TextInput({ text: this.inputText })
        .id('mygoInput')
        .type(InputType.Normal)
        .position({ x: this.inputActive ? this.inputX : -2000, y: this.inputY })
        .width(this.inputActive && this.inputWidth > 0 ? this.inputWidth : 200)
        .height(this.inputActive && this.inputHeight > 0 ? this.inputHeight : 40)
        .backgroundColor('#00000000')
        .onChange((value: string) => {
          host.replaceText(value);
        })
        .onSubmit(() => {
          host.command('enter');
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.windowColor)
  }
}
