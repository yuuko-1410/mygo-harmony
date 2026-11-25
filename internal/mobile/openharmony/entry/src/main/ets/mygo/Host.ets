// The ArkTS host: the calls Go makes of it, and the events it sends Go.
// It starts from HostStubs, which does nothing for the calls this host has
// no use for yet, and adds what a window needs: the surface ArkUI made,
// frames, and touch.

import { AppInfoReply, BatteryReply, CreateWindowCall, CreateWindowReply, Event, FirstFrameCall,
  RequestFrameCall, ScreenReply, SetTitleCall, ShowWindowCall, ThemeReply, dispatchCall } from './Wire';
import { HostStubs } from './HostStubs';

export class Host extends HostStubs {
  // The window Go made last, whose surface the XComponent draws.
  windowId: number = 0;
  dark: boolean = true;
  scale: number = 1;
  // Sends an event to Go: the page's native.event.
  send: (buf: Uint8Array) => void = (buf: Uint8Array) => {};
  private wanted: boolean = false;

  createWindow(c: CreateWindowCall): CreateWindowReply {
    this.windowId = c.id;
    const r = new CreateWindowReply();
    r.error = '';
    r.layer = 0;
    return r;
  }

  showWindow(c: ShowWindowCall): void {
    this.windowId = c.id;
  }

  firstFrame(c: FirstFrameCall): void {}

  setTitle(c: SetTitleCall): void {}

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
    if (this.windowId !== 0) {
      this.send(Event.surfaceChanged(this.windowId, handle, width, height, scale, 60));
    }
  }

  touch(x: number, y: number, phase: string): void {
    if (this.windowId !== 0) {
      this.send(Event.touch(this.windowId, 0, phase, 'touch', x, y, 1, 0, 0));
    }
  }

  // tick runs at the display's refreshes: a frame Go asked for, or none.
  tick(): void {
    if (this.wanted && this.windowId !== 0) {
      this.wanted = false;
      this.send(Event.frame(this.windowId));
    }
  }

  // call runs one call of Go, on the JS thread.
  call(buf: Uint8Array): Uint8Array | null {
    return dispatchCall(this, buf);
  }
}
