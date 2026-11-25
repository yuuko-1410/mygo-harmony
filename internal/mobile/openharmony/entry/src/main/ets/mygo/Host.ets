// The ArkTS host: the calls Go makes of it, and the events it sends Go.
// It starts from HostStubs, which does nothing for the calls this host has
// no use for yet, and adds what a window needs: the surface ArkUI made,
// frames, and touch.

import { AppInfoReply, BatteryReply, CreateWindowCall, CreateWindowReply, Event, FirstFrameCall,
  RequestFrameCall, ScreenReply, SetBackgroundCall, SetFrameRateCall, SetTextInputCall, SetTitleCall,
  ShowWindowCall, ThemeReply, dispatchCall } from './Wire';
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

  setTitle(c: SetTitleCall): void {}

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
    this.send(Event.textMark(this.inputId, true, 0, this.markBase, text, offset, offset + preview.length));
  }

  // replaceText is the user's edit: what the field holds now, which Go puts
  // in place of the document it gave the host, or of the text it marked
  // while it was composing.
  replaceText(text: string): void {
    if (this.inputId === 0 || text === this.inputText) {
      return;
    }
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
