// The NAPI module the page imports: it starts Go, carries the messages of
// package wire between Go and the host, and reports the surface and the
// fingers on it.
export const start: (dispatch: (buf: Uint8Array) => Uint8Array | null,
  onSurface: (handle: number, width: number, height: number, scale: number) => void,
  onDrain: () => void,
  onTouch: (phase: string, x: number, y: number) => void) => void;
export const event: (buf: Uint8Array) => ArrayBuffer | undefined;
export const drain: () => void;
