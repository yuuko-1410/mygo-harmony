import native from 'libentry.so';
import { display, window } from '@kit.ArkUI';
import { windowIds } from './windows';

// A MyGo window beyond the first: its own OS window, its own XComponent.
// MyGo draws into it exactly as it draws into the main one.
@Entry
@Component
struct SubWindow {
  static ownWindow: window.Window | undefined = undefined;
  @State windowId: number = 1;
  @State density: number = 1;

  aboutToAppear(): void {
    this.density = display.getDefaultDisplaySync().densityPixels;
    const id = windowIds.shift();
    if (id !== undefined) {
      this.windowId = id;
    }
  }

  build() {
    Stack() {
      XComponent({ id: `mygo${this.windowId}`, type: 'surface', libraryname: 'entry' })
        .width('100%')
        .height('100%')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const w = Number(newArea.width);
          const h = Number(newArea.height);
          const main = SubWindow.ownWindow?.getWindowProperties().windowRect;
          let density = 0;
          if (main !== undefined && main.width > 0) {
            density = main.width / w;
          }
          native.resizeId(this.windowId, w, h, density);
        })
        .onAxisEvent((event: AxisEvent) => {
          if (event.action === AxisAction.UPDATE) {
            native.scroll(event.getHorizontalAxisValue(), event.getVerticalAxisValue(), event.x, event.y);
          }
        })
    }
    .width('100%')
    .height('100%')
  }
}
