//go:build openharmony

package text

import (
	"fmt"
	"math"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// libnative_drawing is OpenHarmony's 2D drawing and text stack: the font
// manager finds HarmonyOS Sans and the fallbacks, fonts shape text and make
// glyph outlines, and a canvas rasterizes them.

type ohMetrics struct {
	Flags                           uint32
	Top, Ascent, Descent, Bottom    float32
	Leading, AvgCharWidth, MaxCharW float32
	XMin, XMax                      float32
}

type ohFontStyle struct {
	Weight, Width, Slant int32
}

type ohBitmapFormat struct {
	ColorFormat, AlphaFormat int32
}

const (
	ohColorFormatAlpha8 = 1 // COLOR_FORMAT_ALPHA_8
	ohAlphaFormatPremul = 2 // ALPHA_FORMAT_PREMUL
	ohTextEncodingUTF8  = 0 // TEXT_ENCODING_UTF8
	ohFontWidthNormal   = 5 // FONT_WIDTH_NORMAL
	ohFontStyleNormal   = 0 // FONT_STYLE_NORMAL
	ohFontStyleItalic   = 1 // FONT_STYLE_ITALIC
)

var (
	ohLoadOnce sync.Once
	ohLoadErr  error

	ohFontCreate          func() uintptr
	ohFontDestroy         func(uintptr)
	ohFontSetTextSize     func(uintptr, float32)
	ohFontSetTypeface     func(uintptr, uintptr)
	ohFontGetMetrics      func(uintptr, *ohMetrics) float32
	ohFontTextToGlyphs    func(uintptr, unsafe.Pointer, uint32, int32, *uint16, int32) uint32
	ohFontGetWidths       func(uintptr, *uint16, int32, *float32)
	ohFontGetPathForGlyph func(uintptr, uint16, uintptr) int32

	ohFontMgrCreate           func() uintptr
	ohFontMgrMatchFamilyStyle func(uintptr, *byte, ohFontStyle) uintptr
	ohTypefaceDestroy         func(uintptr)
	ohTypefaceFromFile        func(*byte, int32) uintptr
	ohFontMgrGetFamilyCount   func(uintptr) int32
	ohFontMgrGetFamilyName    func(uintptr, int32) *byte

	ohBitmapCreate    func() uintptr
	ohBitmapDestroy   func(uintptr)
	ohBitmapBuild     func(uintptr, uint32, uint32, *ohBitmapFormat)
	ohBitmapGetPixels func(uintptr) unsafe.Pointer
	ohBitmapGetRowBytes func(uintptr, *uint32)

	ohCanvasCreate      func() uintptr
	ohCanvasDestroy     func(uintptr)
	ohCanvasBind        func(uintptr, uintptr)
	ohCanvasClear       func(uintptr, uint32)
	ohCanvasTranslate   func(uintptr, float32, float32)
	ohCanvasAttachBrush func(uintptr, uintptr)
	ohCanvasDetachBrush func(uintptr)
	ohCanvasDrawPath    func(uintptr, uintptr)

	ohBrushCreate       func() uintptr
	ohBrushDestroy      func(uintptr)
	ohBrushSetColor     func(uintptr, uint32)
	ohBrushSetAntiAlias func(uintptr, bool)

	ohPathCreate    func() uintptr
	ohPathDestroy   func(uintptr)
	ohPathGetBounds func(uintptr, uintptr)

	ohRectCreate    func(float32, float32, float32, float32) uintptr
	ohRectDestroy   func(uintptr)
	ohRectGetLeft   func(uintptr) float32
	ohRectGetTop    func(uintptr) float32
	ohRectGetRight  func(uintptr) float32
	ohRectGetBottom func(uintptr) float32
)

func loadDrawing() error {
	ohLoadOnce.Do(func() {
		lib, err := purego.Dlopen("libnative_drawing.so", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			ohLoadErr = fmt.Errorf("text: cannot load libnative_drawing: %w", err)
			return
		}
		reg := func(fn any, name string) { purego.RegisterLibFunc(fn, lib, name) }
		reg(&ohFontCreate, "OH_Drawing_FontCreate")
		reg(&ohFontDestroy, "OH_Drawing_FontDestroy")
		reg(&ohFontSetTextSize, "OH_Drawing_FontSetTextSize")
		reg(&ohFontSetTypeface, "OH_Drawing_FontSetTypeface")
		reg(&ohFontGetMetrics, "OH_Drawing_FontGetMetrics")
		reg(&ohFontTextToGlyphs, "OH_Drawing_FontTextToGlyphs")
		reg(&ohFontGetWidths, "OH_Drawing_FontGetWidths")
		reg(&ohFontGetPathForGlyph, "OH_Drawing_FontGetPathForGlyph")
		reg(&ohFontMgrCreate, "OH_Drawing_FontMgrCreate")
		reg(&ohFontMgrMatchFamilyStyle, "OH_Drawing_FontMgrMatchFamilyStyle")
		reg(&ohTypefaceDestroy, "OH_Drawing_TypefaceDestroy")
		reg(&ohTypefaceFromFile, "OH_Drawing_TypefaceCreateFromFile")
		reg(&ohFontMgrGetFamilyCount, "OH_Drawing_FontMgrGetFamilyCount")
		reg(&ohFontMgrGetFamilyName, "OH_Drawing_FontMgrGetFamilyName")
		reg(&ohBitmapCreate, "OH_Drawing_BitmapCreate")
		reg(&ohBitmapDestroy, "OH_Drawing_BitmapDestroy")
		reg(&ohBitmapBuild, "OH_Drawing_BitmapBuild")
		reg(&ohBitmapGetPixels, "OH_Drawing_BitmapGetPixels")
		reg(&ohBitmapGetRowBytes, "OH_Drawing_BitmapGetRowBytes")
		reg(&ohCanvasCreate, "OH_Drawing_CanvasCreate")
		reg(&ohCanvasDestroy, "OH_Drawing_CanvasDestroy")
		reg(&ohCanvasBind, "OH_Drawing_CanvasBind")
		reg(&ohCanvasClear, "OH_Drawing_CanvasClear")
		reg(&ohCanvasTranslate, "OH_Drawing_CanvasTranslate")
		reg(&ohCanvasAttachBrush, "OH_Drawing_CanvasAttachBrush")
		reg(&ohCanvasDetachBrush, "OH_Drawing_CanvasDetachBrush")
		reg(&ohCanvasDrawPath, "OH_Drawing_CanvasDrawPath")
		reg(&ohBrushCreate, "OH_Drawing_BrushCreate")
		reg(&ohBrushDestroy, "OH_Drawing_BrushDestroy")
		reg(&ohBrushSetColor, "OH_Drawing_BrushSetColor")
		reg(&ohBrushSetAntiAlias, "OH_Drawing_BrushSetAntiAlias")
		reg(&ohPathCreate, "OH_Drawing_PathCreate")
		reg(&ohPathDestroy, "OH_Drawing_PathDestroy")
		reg(&ohPathGetBounds, "OH_Drawing_PathGetBounds")
		reg(&ohRectCreate, "OH_Drawing_RectCreate")
		reg(&ohRectDestroy, "OH_Drawing_RectDestroy")
		reg(&ohRectGetLeft, "OH_Drawing_RectGetLeft")
		reg(&ohRectGetTop, "OH_Drawing_RectGetTop")
		reg(&ohRectGetRight, "OH_Drawing_RectGetRight")
		reg(&ohRectGetBottom, "OH_Drawing_RectGetBottom")
	})
	return ohLoadErr
}

// ohTypeface returns the typeface of family at the style, or the system's
// default font when the family is not there.
func (e *ohEngine) ohTypeface(family string, weight int, italic bool) uintptr {
	slant := int32(ohFontStyleNormal)
	if italic {
		slant = ohFontStyleItalic
	}
	style := ohFontStyle{Weight: int32(weight), Width: ohFontWidthNormal, Slant: slant}
	var name *byte
	var keep []byte
	if family != "" {
		keep = append([]byte(family), 0)
		name = &keep[0]
	}
	tf := ohFontMgrMatchFamilyStyle(e.mgr, name, style)
	if tf == 0 {
		tf = ohFontMgrMatchFamilyStyle(e.mgr, nil, style)
	}
	return tf
}

// ohGlyph rasterizes glyph id of font (an OH_Drawing_Font at the
// rasterization size) into coverage.
func ohGlyph(font uintptr, id uint32) bitmap {
	path := ohPathCreate()
	if path == 0 {
		return bitmap{}
	}
	defer ohPathDestroy(path)
	if ohFontGetPathForGlyph(font, uint16(id), path) != 0 {
		return bitmap{}
	}
	rect := ohRectCreate(0, 0, 0, 0)
	if rect == 0 {
		return bitmap{}
	}
	ohPathGetBounds(path, rect)
	l, t := ohRectGetLeft(rect), ohRectGetTop(rect)
	r, b := ohRectGetRight(rect), ohRectGetBottom(rect)
	ohRectDestroy(rect)
	if !(r > l) || !(b > t) {
		return bitmap{}
	}
	const margin = 6
	left := int(math.Floor(float64(l))) - margin
	top := int(math.Floor(float64(t))) - margin
	w := int(math.Ceil(float64(r))) - left + margin
	h := int(math.Ceil(float64(b))) - top + margin
	if w <= 0 || h <= 0 || w > 4096 || h > 4096 {
		return bitmap{}
	}

	format := ohBitmapFormat{ColorFormat: ohColorFormatAlpha8, AlphaFormat: ohAlphaFormatPremul}
	bm := ohBitmapCreate()
	if bm == 0 {
		return bitmap{}
	}
	defer ohBitmapDestroy(bm)
	ohBitmapBuild(bm, uint32(w), uint32(h), &format)

	canvas := ohCanvasCreate()
	if canvas == 0 {
		return bitmap{}
	}
	defer ohCanvasDestroy(canvas)
	ohCanvasBind(canvas, bm)
	ohCanvasClear(canvas, 0)

	brush := ohBrushCreate()
	if brush == 0 {
		return bitmap{}
	}
	defer ohBrushDestroy(brush)
	ohBrushSetAntiAlias(brush, true)
	ohBrushSetColor(brush, 0xFFFFFFFF)
	ohCanvasAttachBrush(canvas, brush)
	ohCanvasTranslate(canvas, -float32(left), -float32(top))
	ohCanvasDrawPath(canvas, path)
	ohCanvasDetachBrush(canvas)

	var rowBytes uint32
	ohBitmapGetRowBytes(bm, &rowBytes)
	if rowBytes == 0 { rowBytes = uint32(w) }
	pix := make([]byte, w*h)
	srcAll := unsafe.Slice((*byte)(ohBitmapGetPixels(bm)), int(rowBytes)*h)
	for y := 0; y < h; y++ {
		copy(pix[y*w:(y+1)*w], srcAll[y*int(rowBytes):y*int(rowBytes)+w])
	}
	return bitmap{left: left, top: top, w: w, h: h, pix: pix}
}
