import native from 'libentry.so';
import { display, promptAction, window } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { windowIds } from './windows';
import { ConfigurationConstant } from '@kit.AbilityKit';

class Empty {}

class TextResult {
  text: string = '';
}

class Answer {
  response: number = 0;
  checked: boolean = false;
}

class NormalBody {
  title: string = '';
  text: string = '';
  additionalText: string = '';
}

class DeviceInfo {
  type: string = '';
}

class ScreenInfo {
  widthPx: number = 0;
  heightPx: number = 0;
  density: number = 1;
  refreshRate: number = 60;
}

class ThemeInfo {
  dark: boolean = false;
}

class Paths {
  paths: string[] = [];
}

function normalBody(title: string, text: string): notificationManager.NotificationBasicContent {
  const b = new NormalBody();
  b.title = title;
  b.text = text;
  return b;
}

function contentOf(title: string, text: string): notificationManager.NotificationContent {
  const c: notificationManager.NotificationContent = {
    notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
    normal: normalBody(title, text),
  };
  return c;
}

// Extra MyGo windows are OS subwindows, each with its own page and
// XComponent, so the desktop manages them (title bar, moving, stacking).
let windowStageRef: window.WindowStage | undefined = undefined;
const subWindows: Map<number, window.Window> = new Map<number, window.Window>();

async function createSubWindow(id: number): Promise<void> {
  const stage = windowStageRef ?? AppStorage.get<window.WindowStage>('windowStage');
  if (stage === undefined || subWindows.has(id)) {
    return;
  }
  const sub = await stage.createSubWindow(`mygo${id}`);
  subWindows.set(id, sub);
  // The page learns which window it draws: every subwindow has a page of
  // its own, and the XComponent of each takes its own name.
  windowIds.push(id);
  await sub.setUIContent('pages/SubWindow');
  const density = display.getDefaultDisplaySync().densityPixels;
  await sub.resize(360 * density, 300 * density);
  await sub.moveWindowTo((80 + id * 40) * density, (80 + id * 40) * density);
  await sub.showWindow();
  sub.on('windowEvent', (event: window.WindowEventType): void => {
    if (event === window.WindowEventType.WINDOW_DESTROYED) {
      subWindows.delete(id);
      native.windowClosed(id);
    }
  });
}

async function handleHost(ctx: common.UIAbilityContext, op: string, args: Record<string, Object>): Promise<Object> {
  if (op === 'clipboard.write') {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, args.text as string);
    await pasteboard.getSystemPasteboard().setData(data);
    return new Empty();
  }
  if (op === 'clipboard.read') {
    const data = await pasteboard.getSystemPasteboard().getData();
    const r = new TextResult();
    r.text = data.getPrimaryText();
    return r;
  }
  if (op === 'dialog.message') {
    const labels = (args.buttons ?? []) as string[];
    const buttons: promptAction.Button[] = [];
    for (let i = 0; i < labels.length; i++) {
      const b: promptAction.Button = { text: labels[i], color: '#1862fa' };
      buttons.push(b);
    }
    if (buttons.length === 0) {
      const ok: promptAction.Button = { text: 'OK', color: '#1862fa' };
      buttons.push(ok);
    }
    const res = await promptAction.showDialog({
      title: args.title as string,
      message: args.message as string,
      buttons: buttons,
    });
    const a = new Answer();
    a.response = res.index ?? 0;
    return a;
  }
  if (op === 'dialog.open') {
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = (args.multiple as boolean) ? 8 : 1;
    const view = new picker.DocumentViewPicker(ctx);
    const uris = await view.select(opts);
    const r = new Paths();
    r.paths = uris;
    return r;
  }
  if (op === 'dialog.save') {
    const opts = new picker.DocumentSaveOptions();
    opts.newFileNames = [args.name as string];
    const view = new picker.DocumentViewPicker(ctx);
    const uris = await view.save(opts);
    const r = new Paths();
    r.paths = uris;
    return r;
  }
  if (op === 'window.close') {
    const id = args.id as number;
    const sub = subWindows.get(id);
    if (sub !== undefined) {
      subWindows.delete(id);
      await sub.destroyWindow();
    }
    return new Empty();
  }
  if (op === 'window.create') {
    await createSubWindow(args.id as number);
    return new Empty();
  }
  if (op === 'notification.show') {
    await notificationManager.requestEnableNotification();
    const request: notificationManager.NotificationRequest = {
      id: 1,
      content: contentOf(args.title as string, args.body as string),
    };
    await notificationManager.publish(request);
    return new Empty();
  }
  if (op === 'notification.remove' || op === 'notification.clear') {
    await notificationManager.cancelAll();
    return new Empty();
  }
  if (op === 'shell.open') {
    await ctx.startAbility({ action: 'ohos.want.action.viewData', uri: args.uri as string });
    return new Empty();
  }
  if (op === 'device.info') {
    const d = new DeviceInfo();
    d.type = deviceInfo.deviceType;
    return d;
  }
  if (op === 'screen.info') {
    const d = display.getDefaultDisplaySync();
    const s = new ScreenInfo();
    s.widthPx = d.width;
    s.heightPx = d.height;
    s.density = d.densityPixels;
    s.refreshRate = d.refreshRate;
    return s;
  }
  if (op === 'theme.info') {
    const t = new ThemeInfo();
    t.dark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    return t;
  }
  throw new Error(`unknown host call ${op}`);
}

@Entry
@Component
struct Index {
  @State imeOn: boolean = false;
  @State imeText: string = '';
  @State imeX: number = 0;
  @State imeY: number = 0;
  @State imeW: number = 1;
  @State imeH: number = 1;

  aboutToAppear(): void {
    windowStageRef = AppStorage.get<window.WindowStage>('windowStage');
    const d = display.getDefaultDisplaySync();
    native.setTextInputListener((json: string) => {
      const s = JSON.parse(json) as Record<string, Object>;
      this.imeOn = s.on as boolean;
      this.imeText = s.text as string;
      this.imeX = s.x as number;
      this.imeY = s.y as number;
      this.imeW = Math.max(1, s.w as number);
      this.imeH = Math.max(1, s.h as number);
    });
    native.setHostCallListener((json: string) => {
      const req = JSON.parse(json) as Record<string, Object>;
      const id = req.id as number;
      handleHost(getContext(this) as common.UIAbilityContext, req.op as string, (req.args ?? {}) as Record<string, Object>)
        .then((result: Object): void => {
          native.hostReply(JSON.stringify({ id: id, result: result }));
        })
        .catch((e: Error): void => {
          native.hostReply(JSON.stringify({ id: id, error: String(e) }));
        });
    });
    try {
      native.start(getContext(this).filesDir, d.densityPixels);
    } catch (e) {
      console.error(`MYGO start failed: ${e}`);
    }
  }

  build() {
    Stack() {
      XComponent({ id: 'mygo', type: 'surface', libraryname: 'entry' })
        .width('100%')
        .height('100%')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const w = Number(newArea.width);
          const h = Number(newArea.height);
          // The window's own density: the display's may differ, and the
          // surface must be as many pixels as the window has.
          const rect = windowStageRef?.getMainWindowSync().getWindowProperties().windowRect;
          let density = 0;
          if (rect !== undefined && rect.width > 0) {
            density = rect.width / w;
          }
          native.resize(w, h, density);
        })
        .onAxisEvent((event: AxisEvent) => {
          if (event.action === AxisAction.UPDATE) {
            native.scroll(event.getHorizontalAxisValue(), event.getVerticalAxisValue(), event.x, event.y);
          }
        })
      if (this.imeOn) {
        TextInput({ text: this.imeText })
          .position({ x: this.imeX, y: this.imeY })
          .width(this.imeW)
          .height(this.imeH)
          .opacity(0.02)
          .caretColor(Color.Transparent)
          .onChange((v: string) => {
            native.textInputEvent(JSON.stringify({ text: v, composing: false, from: 0, to: 0 }));
          })
      }
    }
    .width('100%')
    .height('100%')
  }
}
