import native from 'libentry.so';
import displaySync from '@ohos.graphics.displaySync';
import display from '@ohos.display';
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

  aboutToAppear(): void {
    host.send = (buf: Uint8Array): void => {
      native.event(buf);
    };
    const d = display.getDefaultDisplaySync();
    host.scale = d.densityPixels;
    this.sync.setExpectedFrameRateRange({ expected: 60, min: 60, max: 120 });
    this.sync.on('frame', () => {
      host.tick();
    });
    this.sync.start();
  }

  aboutToDisappear(): void {
    this.sync.stop();
  }

  build() {
    Column() {
      // The window ArkUI makes for Go, whose surface the module reports.
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
            });
          // Not Event.ready: the backend posts that itself (postReady), and
          // a second one closes a channel twice.
          native.event(Event.active(true));
        })
        .onTouch((event: TouchEvent) => {
          if (event.touches.length === 0) {
            return;
          }
          const t = event.touches[0];
          try {
            switch (event.type) {
              case TouchType.Down:
                host.touch(t.x, t.y, 'down');
                break;
              case TouchType.Move:
                host.touch(t.x, t.y, 'move');
                break;
              case TouchType.Up:
                host.touch(t.x, t.y, 'up');
                break;
              default:
                host.touch(t.x, t.y, 'cancel');
                break;
            }
          } catch (e) {
            // A touch Go has no window for yet.
          }
        })
    }
    .width('100%')
    .height('100%')
  }
}
