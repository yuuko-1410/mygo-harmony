import native from 'libentry.so';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { webControllers } from './webs';

// MyGoPage is the page of a MyGo window whose content is a page: the Web
// component takes the whole window, where a native UI window has its
// XComponent. Go makes one per such window (web.create), commands it
// (web.load, web.eval, …), and serves the app's own URLs — mygo://localhost/
// is its frontend — through the interceptor this component has.
//
// The page reaches Go through the object mygoAndroid, which the bridge of
// internal/bridge calls.

class SchemeReply {
  status: number = 200;
  reason: string = '';
  mime: string = '';
  header: Record<string, string[]> = {};
  body: string = '';
}

// Proxy is the object the page calls: the bridge's mygoAndroid.
class Proxy {
  windowId: number = 0;

  postMessage(msg: string): void {
    native.webMessage(this.windowId, msg);
  }

  asyncResult(id: number, result: string): void {
    native.webAsyncResult(id, result);
  }

  closeWindow(): void {
    native.webCloseRequest(this.windowId);
  }
}

@Component
export struct MyGoPage {
  @Prop windowId: number = 0;
  controller: webview.WebviewController = new webview.WebviewController();
  proxy: Proxy = new Proxy();

  aboutToAppear(): void {
    console.info(`MYGOBOOT page ${this.windowId} appears`);
    this.proxy.windowId = this.windowId;
    webControllers.set(this.windowId, this.controller);
    native.webReady(this.windowId);
  }

  aboutToDisappear(): void {
    webControllers.delete(this.windowId);
    native.windowClosed(this.windowId);
  }

  // response is what Go answered, as the Web component takes it.
  static response(r: SchemeReply): WebResourceResponse {
    const res = new WebResourceResponse();
    res.setResponseCode(r.status);
    if (r.reason !== '') {
      res.setReasonMessage(r.reason);
    }
    if (r.mime !== '') {
      res.setResponseMimeType(r.mime);
    }
    const headers: Array<Header> = [];
    const all: Record<string, string[]> = r.header ?? {};
    const keys = Object.keys(all);
    for (let i = 0; i < keys.length; i++) {
      const values = all[keys[i]];
      for (let j = 0; j < values.length; j++) {
        const h: Header = { headerKey: keys[i], headerValue: values[j] };
        headers.push(h);
      }
    }
    if (headers.length > 0) {
      res.setResponseHeader(headers);
    }
    res.setResponseEncoding('utf-8');
    if (r.body !== '') {
      const bytes = new util.Base64Helper().decodeSync(r.body);
      res.setResponseData(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    } else {
      res.setResponseData(new ArrayBuffer(0));
    }
    return res;
  }

  // intercept hands a request to Go, which serves the app's frontend and the
  // schemes the app handles itself. The host answers at once, so Go serves it
  // here and now.
  intercept(event: OnInterceptRequestEvent): WebResourceResponse {
    try {
      return this.serve(event);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`MYGOWEB intercept ${event.request.getRequestUrl()}: ${err.message}`);
      const failed = new WebResourceResponse();
      failed.setResponseCode(500);
      failed.setReasonMessage('Internal Server Error');
      failed.setResponseMimeType('text/plain');
      failed.setResponseData(new ArrayBuffer(0));
      return failed;
    }
  }

  serve(event: OnInterceptRequestEvent): WebResourceResponse {
    const req = event.request;
    const list = req.getRequestHeader();
    const headers: Array<Header> = [];
    for (let i = 0; i < list.length; i++) {
      const h: Header = { headerKey: list[i].headerKey, headerValue: list[i].headerValue };
      headers.push(h);
    }
    const json: string = native.webScheme(this.windowId, req.getRequestUrl(), req.getRequestMethod(),
      JSON.stringify(headers), '');
    return MyGoPage.response(JSON.parse(json) as SchemeReply);
  }

  build() {
    Stack() {
      Web({ src: '', controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptProxy({
          object: this.proxy,
          name: 'mygoAndroid',
          methodList: ['postMessage', 'asyncResult', 'closeWindow'],
          controller: this.controller,
        })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .onlineImageAccess(true)
        .mixedMode(MixedMode.All)
        .horizontalScrollBarAccess(false)
        .verticalScrollBarAccess(false)
        .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse => {
          return this.intercept(event);
        })
        .onPageBegin((event: OnPageBeginEvent): void => {
          native.webNav(this.windowId, 0, event.url, 0);
        })
        .onPageEnd((event: OnPageEndEvent): void => {
          native.webNav(this.windowId, 1, event.url, 0);
          this.reportHistory();
        })
        .onTitleReceive((event: OnTitleReceiveEvent): void => {
          native.webNav(this.windowId, 2, event.title, 0);
        })
        .onErrorReceive((event: OnErrorReceiveEvent): void => {
          native.webNav(this.windowId, 4, event.request.getRequestUrl(), event.error.getErrorCode());
        })
        .onControllerAttached((): void => {
          this.reportHistory();
        })
    }
    .width('100%')
    .height('100%')
  }

  reportHistory(): void {
    let back = 0;
    let fwd = 0;
    try {
      back = this.controller.accessBackward() ? 1 : 0;
      fwd = this.controller.accessForward() ? 1 : 0;
    } catch (e) {
      const err = e as BusinessError;
      console.info(`MYGOWEB history: ${err.message}`);
    }
    native.webHistory(this.windowId, back, fwd);
  }
}
