// A page of a surface's child window: the app draws around it, and this is
// the web view it made, at the place Go said.
import webview from '@ohos.web.webview';
import { shared } from '../mygo/Shared';

@Entry
@Component
struct Embedded {
  private controller: webview.WebviewController = new webview.WebviewController();
  private windowId: number = 0;

  aboutToAppear(): void {
    const id = LocalStorage.getShared().get<number>('id');
    if (id === undefined) {
      return;
    }
    this.windowId = id;
    shared.registerWeb(id, this.controller);
  }

  aboutToDisappear(): void {
    shared.unregisterWeb(this.windowId);
  }

  build() {
    Column() {
      Web({ src: 'about:blank', controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        // The controller is the component's only once it is attached.
        .onControllerAttached(() => {
          const url = shared.webSource(this.windowId);
          if (url.length > 0) {
            this.controller.loadUrl(url);
          }
        })
        .onPageBegin((event: OnPageBeginEvent) => {
          shared.webBegan(this.windowId, event.url);
        })
        .onPageEnd((event: OnPageEndEvent) => {
          shared.webEnded(this.windowId, event.url, event.url);
        })
        .onErrorReceive((event: OnErrorReceiveEvent) => {
          if (event.error) {
            shared.webFailed(this.windowId, event.request.getRequestUrl(), event.error.getErrorCode(),
              event.error.getErrorInfo());
          }
        })
    }
    .width('100%')
    .height('100%')
  }
}
