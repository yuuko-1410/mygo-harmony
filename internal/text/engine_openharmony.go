//go:build openharmony || (linux && ohos)

package text

import (
	"errors"
	"os"
	"path/filepath"
	"math"
	"strconv"
	"unsafe"

	"log"

	"github.com/egoist/mygo/internal/scene"
)

// ohEngine lays text out and rasterizes glyphs with OpenHarmony's native
// drawing stack: OH_Drawing_FontMgr finds HarmonyOS Sans and the fallbacks,
// OH_Drawing_Font shapes and outlines glyphs, and a canvas rasterizes them
// into coverage atlases. A Font keeps the typeface it matched; a font at a
// rasterization size is made on demand.
type ohEngine struct {
	shapeScratch
	mgr    uintptr
	fonts  map[string]*Font
	scaled map[[2]uint64]uintptr
	appFonts []FontFamily
	appTypefaces map[string]uintptr
}

func newEngine() engine {
	if err := loadDrawing(); err != nil {
		return &stubEngine{}
	}
	e := &ohEngine{
		fonts:  map[string]*Font{},
		scaled: map[[2]uint64]uintptr{},
		appTypefaces: map[string]uintptr{},
	}
	e.mgr = ohFontMgrCreate()
	return e
}

func (e *ohEngine) font(style Style) *Font {
	size := style.Size
	if size <= 0 {
		size = 14
	}
	weight := style.Weight
	if weight == 0 {
		weight = 400
	}
	family := ohFamily(style.Family)
	key := family + "|" + strconv.FormatFloat(float64(size), 'f', 3, 32) + "|" +
		strconv.Itoa(weight) + "|" + strconv.FormatBool(style.Italic)
	if f, ok := e.fonts[key]; ok {
		return f
	}
	tf := e.ohTypeface(family, weight, style.Italic)
	f := &Font{Size: size, native: tf}
	m := ohMetrics{}
	ohFontGetMetrics(e.fontFor(f, size), &m)
	f.Ascent = -m.Ascent
	f.Descent = m.Descent
	f.LineGap = m.Leading
	if f.Ascent <= 0 {
		f.Ascent = size * 0.8
	}
	if f.Descent <= 0 {
		f.Descent = size * 0.2
	}
	f.underlineTop = size * 0.10
	f.underlineThick = maxf(1, size/14)
	f.strikeTop = size * 0.30
	f.strikeThick = maxf(1, size/14)
	e.fonts[key] = f
	return f
}

// fontFor returns an OH_Drawing_Font of f's typeface at size pixels.
func (e *ohEngine) fontFor(f *Font, size float32) uintptr {
	key := [2]uint64{uint64(f.native), uint64(math.Float32bits(size))}
	if font, ok := e.scaled[key]; ok {
		return font
	}
	font := ohFontCreate()
	ohFontSetTextSize(font, size)
	if f.native != 0 {
		ohFontSetTypeface(font, f.native)
	}
	e.scaled[key] = font
	return font
}

// segment is a run of runes of one style.
type segment struct {
	start, end int
	style      Style
}

// segments splits text at the ends of spans.
func segments(text []rune, style Style, spans []Span) []segment {
	var out []segment
	add := func(a, b int, st Style) {
		if b > a {
			out = append(out, segment{start: a, end: b, style: st})
		}
	}
	pos := 0
	for _, sp := range spans {
		if sp.End <= pos {
			continue
		}
		end := sp.End
		if end > len(text) {
			end = len(text)
		}
		add(pos, end, style.withSpan(sp))
		pos = end
	}
	add(pos, len(text), style)
	if len(out) == 0 {
		add(0, len(text), style)
	}
	return out
}

func (s Style) withSpan(sp Span) Style {
	if sp.Family != "" {
		s.Family = sp.Family
	}
	if sp.Size > 0 {
		s.Size = sp.Size
	}
	if sp.Weight != 0 {
		s.Weight = sp.Weight
	}
	s.Italic = sp.Italic
	if sp.SpacingSet || sp.LetterSpacing != 0 {
		s.LetterSpacing = sp.LetterSpacing
	}
	if sp.Features != "" {
		s.Features = sp.Features
	}
	if sp.Lang != "" {
		s.Lang = sp.Lang
	}
	return s
}

func (e *ohEngine) shape(text []rune, style Style, spans []Span, width float32, rtl, wholeWords bool) []shapedLine {
	e.resetScratch()

	var glyphs []Glyph
	pen := float32(0)
	for _, s := range segments(text, style, spans) {
		f := e.font(s.style)
		buf, _ := utf8Text(text[s.start:s.end])
		if len(buf) == 0 {
			continue
		}
		nf := e.fontFor(f, f.Size)
		gids := make([]uint16, len(text[s.start:s.end])+2)
		n := int(ohFontTextToGlyphs(nf, unsafe.Pointer(&buf[0]), uint32(len(buf)),
			ohTextEncodingUTF8, &gids[0], int32(len(gids))))
		if n <= 0 || n > len(gids) {
			continue
		}
		widths := make([]float32, n)
		ohFontGetWidths(nf, &gids[0], int32(n), &widths[0])
		for i := 0; i < n; i++ {
			adv := widths[i] + s.style.LetterSpacing
			glyphs = append(glyphs, Glyph{
				Font:    f,
				ID:      uint32(gids[i]),
				Size:    f.Size,
				X:       pen,
				Advance: adv,
				Cluster: s.start + i,
				Runes:   1,
			})
			pen += adv
		}
	}
	if len(glyphs) == 0 {
		return nil
	}

	var lines []shapedLine
	start := 0
	lineWidth := float32(0)
	for i := range glyphs {
		g := &glyphs[i]
		if width > 0 && i > start && lineWidth+g.Advance > width {
			brk := i
			if !wholeWords {
				for j := i; j > start+1; j-- {
					if r := glyphs[j-1].Cluster; r < len(text) && text[r] == ' ' {
						brk = j
						break
					}
				}
			}
			lines = append(lines, e.line(glyphs[start:brk]))
			start = brk
			lineWidth = 0
			for j := start; j <= i && j < len(glyphs); j++ {
				lineWidth += glyphs[j].Advance
			}
			continue
		}
		lineWidth += g.Advance
	}
	if start < len(glyphs) {
		lines = append(lines, e.line(glyphs[start:]))
	}
	return lines
}

func (e *ohEngine) line(glyphs []Glyph) shapedLine {
	base := glyphs[0].X
	for i := range glyphs {
		glyphs[i].X -= base
	}
	l := shapedLine{start: glyphs[0].Cluster, end: glyphs[len(glyphs)-1].Cluster + 1, mark: -1}
	for i := 0; i < len(glyphs); {
		j := i + 1
		for j < len(glyphs) && glyphs[j].Font == glyphs[i].Font {
			j++
		}
		l.runs = append(l.runs, shapedRun{
			font:   glyphs[i].Font,
			start:  glyphs[i].Cluster,
			end:    glyphs[j-1].Cluster + 1,
			glyphs: glyphs[i:j],
		})
		i = j
	}
	return l
}

func (e *ohEngine) glyph(f *Font, id uint32, scale, dx float32, shade Shade, subpixel bool) bitmap {
	return ohGlyph(e.fontFor(f, f.Size*scale), id)
}

func (e *ohEngine) positions(*Font, float32, bool) (int, bool) { return 1, true }

func (e *ohEngine) baseline(y float32) float32 { return float32(math.Floor(float64(y) + 1e-3)) }

func (e *ohEngine) decorate(r decoRange) []Stroke {
	s := r.scale
	base := r.baseline() * s
	var out []Stroke
	r.runs(func(f *Font, i, j int) {
		x0, x1 := r.span(i, j)
		top, thick := f.strikeTop, f.strikeThick
		if r.d == Underline {
			top, thick = f.underlineTop, f.underlineThick
		}
		out = append(out, Stroke{X0: (r.x + x0) * s, X1: (r.x + x1) * s, Top: base - top*s, Bottom: base - top*s + thick*s})
	})
	return out
}

func maxf(a, b float32) float32 {
	if a > b {
		return a
	}
	return b
}

func (e *ohEngine) join() bool { return false }

func (e *ohEngine) textParams() (scene.TextParams, bool) { return scene.TextParams{}, false }

func (e *ohEngine) register(data []byte, family string) error {
	dir := os.Getenv("MYGO_FILES_DIR")
	if dir == "" {
		dir = os.TempDir()
	}
	path := filepath.Join(dir, "mygo-font-"+strconv.FormatUint(uint64(len(e.appFonts)), 10)+".ttf")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return err
	}
	p := append([]byte(path), 0)
	tf := ohTypefaceFromFile(&p[0], 0)
	if tf == 0 {
		return errors.New("text: cannot load font " + path)
	}
	if family == "" {
		family = filepath.Base(path)
	}
	e.appFonts = append(e.appFonts, FontFamily{Name: family, Registered: true})
	e.appTypefaces[family] = tf
	return nil
}

func (e *ohEngine) appFamilies() []FontFamily { return e.appFonts }

func (e *ohEngine) systemFamilies() func() []FontFamily {
	return func() []FontFamily {
		n := int(ohFontMgrGetFamilyCount(e.mgr))
		out := make([]FontFamily, 0, n)
		for i := 0; i < n; i++ {
			p := ohFontMgrGetFamilyName(e.mgr, int32(i))
			if p == nil {
				continue
			}
			name := goString(p)
			out = append(out, FontFamily{Name: name})
		}
		return out
	}
}

// ohFamily maps a style's family list to the family to match: the first
// family that is not one of the generic names.
func ohFamily(list string) string {
	for _, f := range familyList(list) {
		if generic(f) == "" {
			return f
		}
	}
	return ""
}




var ohLineLogged bool


// goString returns the NUL-terminated string at p.
func goString(p *byte) string {
	if p == nil {
		return ""
	}
	var b []byte
	for q := unsafe.Pointer(p); ; q = unsafe.Add(q, 1) {
		c := *(*byte)(q)
		if c == 0 {
			break
		}
		b = append(b, c)
	}
	return string(b)
}

// debugDumpGlyph logs an ASCII picture of a glyph's coverage, to tell a
// wrong bitmap from wrong sampling downstream.
func (e *ohEngine) debugDumpGlyph(gid uint32, size float32) {
	bm := ohGlyph(e.fontFor(e.font(Style{Size: size}), size), gid)
	log.Printf("ohos glyph dump: gid=%d l=%d t=%d w=%d h=%d pix=%d", gid, bm.left, bm.top, bm.w, bm.h, len(bm.pix))
	if bm.w == 0 || bm.h == 0 {
		return
	}
	const cols = 32
	stepX := bm.w / cols
	if stepX < 1 {
		stepX = 1
	}
	stepY := stepX
	for y := 0; y+stepY <= bm.h; y += stepY {
		line := make([]byte, 0, cols+1)
		for x := 0; x+stepX <= bm.w; x += stepX {
			sum := 0
			for dy := 0; dy < stepY; dy++ {
				for dx := 0; dx < stepX; dx++ {
					sum += int(bm.pix[(y+dy)*bm.w+x+dx])
				}
			}
			switch {
			case sum > stepX*stepY*160:
				line = append(line, '#')
			case sum > stepX*stepY*60:
				line = append(line, '+')
			case sum > 0:
				line = append(line, '.')
			default:
				line = append(line, ' ')
			}
		}
		log.Printf("ohos|%s|", line)
	}
}
