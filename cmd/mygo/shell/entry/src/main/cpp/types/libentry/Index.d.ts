export const start: (filesDir: string, density: number) => void;
export const resize: (widthVp: number, heightVp: number, density: number) => void;
export const setTextInputListener: (cb: (json: string) => void) => void;

export const textInputEvent: (json: string) => void;

export const setHostCallListener: (cb: (json: string) => void) => void;
export const hostReply: (json: string) => void;

export const windowClosed: (id: number) => void;
export const scroll: (dx: number, dy: number, x: number, y: number) => void;
export const resizeId: (id: number, w: number, h: number, density: number) => void;
