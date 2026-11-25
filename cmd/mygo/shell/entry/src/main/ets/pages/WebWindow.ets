import native from 'libentry.so';
import { windowIds } from './windows';
import { MyGoPage } from './MyGoPage';

// The window of a page, beyond the first: MyGo makes it as another OS
// window, as it does for a native UI window, and MyGoPage is what it shows.

@Entry
@Component
struct WebWindow {
  @State windowId: number = 1;

  aboutToAppear(): void {
    const id = windowIds.shift();
    if (id !== undefined) {
      this.windowId = id;
    }
  }

  build() {
    Stack() {
      MyGoPage({ windowId: this.windowId })
    }
    .width('100%')
    .height('100%')
  }
}
