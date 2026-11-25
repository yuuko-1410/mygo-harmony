import native from 'libentry.so';
import displaySync from '@ohos.graphics.displaySync';
import display from '@ohos.display';
import { Host } from '../mygo/Host';
import { Event } from '../mygo/Wire';

@Entry
@Component
struct Index {
  private host: Host = new Host();
  private sync: displaySync.DisplaySync = displaySync.create();
  private started: boolean = false;

  aboutToAppear(): void {
    this.host.send = (buf: Uint8Array): void => {
      native.event(buf);
    };
    const d = display.getDefaultDisplaySync();
    this.host.scale = d.densityPixels;
    this.sync.setExpectedFrameRateRange({ expected: 60, min: 60, max: 120 });
    this.sync.on('frame', () => {
      this.host.tick();
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
          if (this.started) {
            return;
          }
          this.started = true;
          native.start(
            (buf: Uint8Array): Uint8Array | null => this.host.call(buf),
            (handle: number, width: number, height: number, scale: number): void => {
              this.host.surface(handle, width, height, scale === 1 ? this.host.scale : scale);
            },
            (): void => {
              native.drain();
            });
          native.event(Event.ready());
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
                this.host.touch(t.x, t.y, 'down');
                break;
              case TouchType.Move:
                this.host.touch(t.x, t.y, 'move');
                break;
              case TouchType.Up:
                this.host.touch(t.x, t.y, 'up');
                break;
              default:
                this.host.touch(t.x, t.y, 'cancel');
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
