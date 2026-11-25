import { webview } from '@kit.ArkWeb';

// The controllers of the windows whose content is a page, by window id: Go
// commands a page (web.load, web.eval, …) through the controller the Web
// component of its window has, which only that window's page can take.
export const webControllers: Map<number, webview.WebviewController> =
  new Map<number, webview.WebviewController>();

// webCommand runs a command of Go's on the page of a window. It returns
// false when the window has no page yet, or the command is not the page's.
export function webCommand(id: number, op: string, args: Record<string, Object>): boolean {
  const c = webControllers.get(id);
  if (c === undefined) {
    return false;
  }
  if (op === 'web.load') {
    c.loadUrl(args.url as string);
  } else if (op === 'web.html') {
    const base = (args.base ?? '') as string;
    c.loadData(args.html as string, 'text/html', 'utf-8', base);
  } else if (op === 'web.reload') {
    c.refresh();
  } else if (op === 'web.stop') {
    c.stop();
  } else if (op === 'web.back') {
    c.backward();
  } else if (op === 'web.forward') {
    c.forward();
  } else if (op === 'web.eval') {
    c.runJavaScript(args.js as string);
  } else if (op === 'web.zoom') {
    c.zoom(args.factor as number);
  } else {
    return false;
  }
  return true;
}
