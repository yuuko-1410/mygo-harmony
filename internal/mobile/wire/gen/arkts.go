package main

import (
	"bytes"
	"fmt"
	"strings"
)

// ---- ArkTS

var arktsTypes = map[string]string{
	"int": "number", "float": "number", "bool": "boolean", "string": "string",
	"bytes": "Uint8Array", "strings": "string[]", "floats": "number[]",
}
var arktsZero = map[string]string{
	"int": "0", "float": "0", "bool": "false", "string": "''",
	"bytes": "new Uint8Array(0)", "strings": "[]", "floats": "[]",
}

// ArkTS has no 64-bit integers, and its bit operators work on 32 bits, so
// the codec neither shifts nor multiplies past 2^53: the varint is written
// and read with division and multiplication by 128, and the zigzag with
// arithmetic. Pointers (a surface's handle) are below 2^48 on arm64, which
// a double holds exactly.
const arktsCodec = `
/** Writes the values of a message, as package wire encodes them. */
export class WireWriter {
  private buf: Uint8Array = new Uint8Array(64)
  private n: number = 0

  private room(k: number): void {
    if (this.n + k <= this.buf.length) {
      return
    }
    let size = this.buf.length * 2
    while (size < this.n + k) {
      size *= 2
    }
    const next = new Uint8Array(size)
    next.set(this.buf.subarray(0, this.n))
    this.buf = next
  }

  uvarint(v: number): void {
    this.room(10)
    while (v >= 0x80) {
      this.buf[this.n++] = (v % 0x80) + 0x80
      v = Math.floor(v / 0x80)
    }
    this.buf[this.n++] = v
  }

  int(v: number): void {
    if (v >= 0) {
      this.uvarint(v * 2)
    } else {
      this.uvarint(-v * 2 - 1)
    }
  }

  bool(v: boolean): void {
    this.room(1)
    this.buf[this.n++] = v ? 1 : 0
  }

  float(v: number): void {
    this.room(8)
    const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.n, 8)
    view.setFloat64(0, v, true)
    this.n += 8
  }

  bytes(v: Uint8Array): void {
    this.uvarint(v.length)
    this.room(v.length)
    this.buf.set(v, this.n)
    this.n += v.length
  }

  string(v: string): void {
    this.bytes(encodeUTF8(v))
  }

  strings(v: string[]): void {
    this.uvarint(v.length)
    for (const s of v) {
      this.string(s)
    }
  }

  floats(v: number[]): void {
    this.uvarint(v.length)
    for (const f of v) {
      this.float(f)
    }
  }

  done(): Uint8Array {
    return this.buf.slice(0, this.n)
  }
}

/** Reads the values of a message; past its end they read as zero. */
export class WireReader {
  private buf: Uint8Array
  private at: number = 0

  constructor(buf: Uint8Array) {
    this.buf = buf
  }

  done(): boolean {
    return this.at >= this.buf.length
  }

  uvarint(): number {
    let v = 0
    let mul = 1
    while (this.at < this.buf.length) {
      const c = this.buf[this.at++]
      v += (c & 0x7f) * mul
      if (c < 0x80) {
        return v
      }
      mul *= 0x80
    }
    return v
  }

  int(): number {
    const u = this.uvarint()
    return u % 2 === 1 ? -(u + 1) / 2 : u / 2
  }

  bool(): boolean {
    return this.at < this.buf.length ? this.buf[this.at++] !== 0 : false
  }

  float(): number {
    if (this.at + 8 > this.buf.length) {
      this.at = this.buf.length
      return 0
    }
    const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.at, 8)
    this.at += 8
    return view.getFloat64(0, true)
  }

  bytes(): Uint8Array {
    const n = this.uvarint()
    if (this.at + n > this.buf.length) {
      this.at = this.buf.length
      return new Uint8Array(0)
    }
    const b = this.buf.slice(this.at, this.at + n)
    this.at += n
    return b
  }

  string(): string {
    return decodeUTF8(this.bytes())
  }

  strings(): string[] {
    const n = Math.min(this.uvarint(), this.buf.length - this.at)
    const s: string[] = []
    for (let i = 0; i < n; i++) {
      s.push(this.string())
    }
    return s
  }

  floats(): number[] {
    const n = Math.min(this.uvarint(), (this.buf.length - this.at) / 8)
    const f: number[] = []
    for (let i = 0; i < n; i++) {
      f.push(this.float())
    }
    return f
  }
}

/** The bytes of a string, UTF-8, as net/url and JSON would write them. */
function encodeUTF8(s: string): Uint8Array {
  const b = new Uint8Array(s.length * 4)
  let n = 0
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i)
    if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1)
      if (d >= 0xdc00 && d < 0xe000) {
        c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00)
        i++
      }
    }
    if (c < 0x80) {
      b[n++] = c
    } else if (c < 0x800) {
      b[n++] = 0xc0 | (c >> 6)
      b[n++] = 0x80 | (c & 0x3f)
    } else if (c < 0x10000) {
      b[n++] = 0xe0 | (c >> 12)
      b[n++] = 0x80 | ((c >> 6) & 0x3f)
      b[n++] = 0x80 | (c & 0x3f)
    } else {
      b[n++] = 0xf0 | (c >> 18)
      b[n++] = 0x80 | ((c >> 12) & 0x3f)
      b[n++] = 0x80 | ((c >> 6) & 0x3f)
      b[n++] = 0x80 | (c & 0x3f)
    }
  }
  return b.slice(0, n)
}

function decodeUTF8(b: Uint8Array): string {
  let s = ''
  let i = 0
  while (i < b.length) {
    const c = b[i++]
    let r = 0xfffd
    if (c < 0x80) {
      r = c
    } else if (c >= 0xc0 && c < 0xe0 && i < b.length) {
      r = ((c & 0x1f) << 6) | (b[i++] & 0x3f)
    } else if (c >= 0xe0 && c < 0xf0 && i + 1 < b.length) {
      r = ((c & 0x0f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f)
    } else if (c >= 0xf0 && i + 2 < b.length) {
      r = ((c & 0x07) << 18) | ((b[i++] & 0x3f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f)
    }
    if (r >= 0x10000) {
      r -= 0x10000
      s += String.fromCharCode(0xd800 + (r >> 10), 0xdc00 + (r & 0x3ff))
    } else {
      s += String.fromCharCode(r)
    }
  }
  return s
}
`

func arktsSource() []byte {
	var b bytes.Buffer
	fmt.Fprintf(&b, "// %s\n\n/* eslint-disable */\n", header)
	b.WriteString(arktsCodec)
	class := func(name string, fs []field, decode, encode bool) {
		fmt.Fprintf(&b, "\nexport class %s {\n", name)
		for _, f := range fs {
			fmt.Fprintf(&b, "  %s: %s = %s\n", lower(f.name), arktsTypes[f.typ], arktsZero[f.typ])
		}
		b.WriteString("  constructor() {}\n")
		if decode {
			fmt.Fprintf(&b, "  static decode(r: WireReader): %s {\n    const c = new %s()\n", name, name)
			for _, f := range fs {
				fmt.Fprintf(&b, "    c.%s = r.%s()\n", lower(f.name), f.typ)
			}
			b.WriteString("    return c\n  }\n")
		}
		if encode {
			b.WriteString("  encode(w: WireWriter): void {\n")
			for _, f := range fs {
				fmt.Fprintf(&b, "    w.%s(this.%s)\n", f.typ, lower(f.name))
			}
			b.WriteString("  }\n")
		}
		b.WriteString("}\n")
	}
	for _, m := range calls {
		if len(m.args) > 0 {
			class(m.name+"Call", m.args, true, false)
		}
		if m.wait {
			class(m.name+"Reply", m.reply, false, true)
		}
	}
	b.WriteString("\n/** The calls Go makes of the host, on the UI thread. */\nexport interface HostCalls {\n")
	for _, m := range calls {
		sig := "  " + lower(m.name) + "("
		if len(m.args) > 0 {
			sig += "c: " + m.name + "Call"
		}
		sig += ")"
		if m.wait {
			sig += ": " + m.name + "Reply"
		} else {
			sig += ": void"
		}
		if m.doc != "" {
			fmt.Fprintf(&b, "  /** %s */\n", m.doc)
		}
		fmt.Fprintf(&b, "%s\n", sig)
	}
	b.WriteString("}\n\n/** Runs a call on h and encodes its reply, null for a call not waited for. */\nexport function dispatchCall(h: HostCalls, buf: Uint8Array): Uint8Array | null {\n  const r = new WireReader(buf)\n  const w = new WireWriter()\n  switch (r.uvarint()) {\n")
	for i, m := range calls {
		arg := ""
		if len(m.args) > 0 {
			arg = m.name + "Call.decode(r)"
		}
		fmt.Fprintf(&b, "    case %d:\n", i+1)
		if m.wait {
			fmt.Fprintf(&b, "      h.%s(%s).encode(w)\n      return w.done()\n", lower(m.name), arg)
		} else {
			fmt.Fprintf(&b, "      h.%s(%s)\n      return null\n", lower(m.name), arg)
		}
	}
	b.WriteString("    default:\n      return null\n  }\n}\n\n/** Encodes the events the host sends Go. */\nexport class Event {\n")
	for i, m := range events {
		if m.doc != "" {
			fmt.Fprintf(&b, "  /** %s */\n", m.doc)
		}
		var ps []string
		for _, f := range m.args {
			ps = append(ps, lower(f.name)+": "+arktsTypes[f.typ])
		}
		fmt.Fprintf(&b, "  static %s(%s): Uint8Array {\n    const w = new WireWriter()\n    w.uvarint(%d)\n", lower(m.name), strings.Join(ps, ", "), i+1)
		for _, f := range m.args {
			fmt.Fprintf(&b, "    w.%s(%s)\n", f.typ, lower(f.name))
		}
		b.WriteString("    return w.done()\n  }\n")
	}
	b.WriteString("}\n")
	for _, m := range events {
		if m.wait {
			class(m.name+"Reply", m.reply, true, false)
		}
	}
	return b.Bytes()
}

// arktsHostStubsSource writes the host every call of, unimplemented: the
// ArkTS host embeds it and overrides what it does.
func arktsHostStubsSource() []byte {
	var b bytes.Buffer
	fmt.Fprintf(&b, "// %s\n\n/* eslint-disable */\n\nimport { HostCalls", header)
	var calls_ []string
	for _, m := range calls {
		if len(m.args) > 0 {
			calls_ = append(calls_, m.name+"Call")
		}
		if m.wait {
			calls_ = append(calls_, m.name+"Reply")
		}
	}
	b.WriteString(", " + strings.Join(calls_, ", ") + " } from './Wire'\n")
	b.WriteString("\n/** The calls a host does not implement: they log and do nothing. */\nexport class HostStubs implements HostCalls {\n  protected unsupported(name: string): void {\n    console.info(`mygo: the host does not implement ${name}`)\n  }\n")
	for _, m := range calls {
		sig := "  " + lower(m.name) + "("
		if len(m.args) > 0 {
			sig += "c: " + m.name + "Call"
		}
		sig += ")"
		if m.wait {
			sig += ": " + m.name + "Reply"
		} else {
			sig += ": void"
		}
		if m.doc != "" {
			fmt.Fprintf(&b, "  /** %s */\n", m.doc)
		}
		fmt.Fprintf(&b, "%s {\n    this.unsupported('%s')\n", sig, lower(m.name))
		if m.wait {
			fmt.Fprintf(&b, "    return new %sReply()\n", m.name)
		}
		b.WriteString("  }\n")
	}
	b.WriteString("}\n")
	return b.Bytes()
}
