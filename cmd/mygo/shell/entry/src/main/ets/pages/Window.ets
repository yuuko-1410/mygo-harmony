// A window of the app's own: it draws with a component of its own, into the
// native window the system made for it.
import native from 'libentry.so';
import { shared as host } from '../mygo/Shared';
import { Event } from '../mygo/Wire';

@Entry
@Component
struct Win {
  // Not `id`: that is ArkUI's own, inherited by the struct.
  private windowId: number = 0;
  @State private windowColor: number = 0xff000000;

  aboutToAppear(): void {
    const id = LocalStorage.getShared().get<number>('id');
    if (id !== undefined) {
      this.windowId = id;
    }
    this.windowColor = host.background;
  }

  build() {
    Column() {
      XComponent({ id: `mygo-${this.windowId}`, type: XComponentType.SURFACE, libraryname: 'entry' })
        .width('100%')
        .height('100%')
        // The component asks which window it draws for, once the module has
        // it: a window of the app's has one of its own.
        .onLoad(() => {
          native.bind(this.windowId);
          host.send(Event.active(true));
        })
        .onAxisEvent((event: AxisEvent) => {
          if (event.action !== AxisAction.UPDATE) {
            return;
          }
          const scale = host.scaleOf.get(this.windowId) ?? host.scale;
          const s = scale > 0 ? scale : 1;
          host.wheelAt(this.windowId, (event.displayX ?? 0) / s, (event.displayY ?? 0) / s,
            event.axisHorizontal ?? 0, event.axisVertical ?? 0);
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.windowColor)
  }
}
