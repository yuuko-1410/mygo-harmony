export const start: (filesDir: string, density: number) => void;
export const resize: (widthVp: number, heightVp: number, density: number) => void;
export const setTextInputListener: (cb: (json: string) => void) => void;

export const textInputEvent: (json: string) => void;

export const setHostCallListener: (cb: (json: string) => void) => void;
export const hostReply: (json: string) => void;

export const windowClosed: (id: number) => void;
export const scroll: (dx: number, dy: number, x: number, y: number) => void;
export const resizeId: (id: number, w: number, h: number, density: number) => void;
export const webReady: (id: number) => void;
export const webNav: (id: number, kind: number, text: string, code: number) => void;
export const webHistory: (id: number, canBack: number, canFwd: number) => void;
export const webMessage: (id: number, msg: string) => void;
export const webAsyncResult: (id: number, result: string) => void;
export const webScheme: (id: number, url: string, method: string, header: string, body: string) => string;
export const webCloseRequest: (id: number) => void;
