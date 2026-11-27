package main

import (
	"bytes"
	"embed"
	"fmt"
	"image/png"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/egoist/mygo/internal/mobile/openharmony"
)

// The native shell of a HAP: the ArkTS page and its XComponents, the C++ that
// loads the app's Go code and passes it the window, the IME overlay, the
// subwindow page, and the HAP's own manifests. It is the same for every app,
// so it ships with the tool.
//
//go:embed all:shell
var shellFS embed.FS


// writeHost copies the host's own files — the pages, the module they import
// and the C++ — over the shell's, so that there is one copy of them: the one
// in internal/mobile/openharmony, which go generate keeps current.
func writeHost(dest string) error {
	return fs.WalkDir(openharmony.Entry, "entry", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		target := filepath.Join(dest, path)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := fs.ReadFile(openharmony.Entry, path)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
}

// hapShell is what every HAP project has, by which one is known.
const hapShell = "entry/src/main/cpp/CMakeLists.txt"

// ohosInit writes the shell into dest and names it: bundle in the manifests,
// the app's name where the shell shows it, and no signing material, which
// belongs to the old bundle (devecocli signature generate makes the new one).
func ohosInit(dest, bundle, label, icon string) error {
	if entries, err := os.ReadDir(dest); err == nil && len(entries) > 0 {
		return fmt.Errorf("mygo ohos init: %s is not empty", dest)
	}
	if err := ohosWriteShell(dest, bundle, label, "", icon); err != nil {
		return err
	}
	fmt.Printf("== %s: the shell of a HAP project, %s (%s)\n", dest, bundle, label)
	fmt.Printf(`Next, once per bundle:

  cd %s && devecocli signature generate

then build and run the app:

  mygo ohos run <app dir> -hap %s
`, dest, dest)
	return nil
}

// ohosWriteShell writes the shell into dest, which may be a project already:
// the files that changed are written, the others left as they are, so that
// the signing material of a project built before stays (a signed build).
func ohosWriteShell(dest, bundle, label, version, icon string) error {
	root, err := fs.Sub(shellFS, "shell")
	if err != nil {
		return err
	}
	err = fs.WalkDir(root, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		target := filepath.Join(dest, path)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := fs.ReadFile(root, path)
		if err != nil {
			return err
		}
		switch filepath.Base(path) {
		case "app.json5":
			data = setJSONString(data, "bundleName", bundle)
			if version != "" {
				data = setJSONString(data, "versionName", version)
				data = setJSONNumber(data, "versionCode", ohosVersionCode(version))
			}
		case "module.json5":
			data = setJSONString(data, "bundleName", bundle)
		case "string.json":
			data = setJSONString(data, "value", label) // the shell's own name
		case "Index.ets":
			data = []byte(strings.ReplaceAll(string(data), "'MyGo'", "'"+label+"'"))
		case "build-profile.json5":
			if old, err := os.ReadFile(target); err == nil && bytes.Contains(old, []byte(`"signingConfigs"`)) {
				return nil // its own signing material, which this would drop
			}
			data = dropSigningConfigs(data)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
	if err != nil {
		return err
	}
	if icon != "" {
		if err := ohosWriteIcon(dest, icon); err != nil {
			return err
		}
	}
	// The host is one copy, of the package that holds it: written last, so
	// that the shell's scaffolding and the host's files are one project.
	return writeHost(dest)
}

// ohosWriteIcon puts the app's icon where the shell shows it: a layered icon
// of a background and a foreground, as HarmonyOS draws them, and the icon the
// window shows as the app starts. The foreground keeps the icon's alpha, on
// the transparent 1024 square the layer expects.
func ohosWriteIcon(dest, icon string) error {
	data, err := os.ReadFile(icon)
	if err != nil {
		return err
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("%s: %v", icon, err)
	}
	fg := resize(img, 1024)
	start := resize(img, 288)
	for _, dir := range []string{
		filepath.Join(dest, "AppScope/resources/base/media"),
		filepath.Join(dest, "entry/src/main/resources/base/media"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		var b bytes.Buffer
		if err := png.Encode(&b, fg); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "foreground.png"), b.Bytes(), 0o644); err != nil {
			return err
		}
	}
	var b bytes.Buffer
	if err := png.Encode(&b, start); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dest, "entry/src/main/resources/base/media/startIcon.png"), b.Bytes(), 0o644)
}

// setJSONString sets the value of the first "key": "value" of the JSON-ish
// manifests, which are JSON5: comments and trailing commas, which this
// leaves alone.
func setJSONString(data []byte, key, value string) []byte {
	pattern := regexp.MustCompile(`("` + regexp.QuoteMeta(key) + `"\s*:\s*")[^"]*(")`)
	return pattern.ReplaceAll(data, []byte("${1}"+value+"${2}"))
}

// setJSONNumber sets the value of the first "key": number of the manifests.
func setJSONNumber(data []byte, key string, value int) []byte {
	pattern := regexp.MustCompile(`("` + regexp.QuoteMeta(key) + `"\s*:\s*)\d+`)
	return pattern.ReplaceAll(data, []byte("${1}"+strconv.Itoa(value)))
}

// ohosVersionCode is the integer an AppGallery orders uploads by, as
// Android's is: 10000 per major, 100 per minor.
func ohosVersionCode(version string) int {
	p := strings.SplitN(strings.SplitN(version, "-", 2)[0], ".", 3)
	n := 0
	for i, mul := range []int{10000, 100, 1} {
		if i < len(p) {
			v, _ := strconv.Atoi(p[i])
			n += v * mul
		}
	}
	return max(n*100, 100)
}

// dropSigningConfigs removes the signingConfigs array, which signs the bundle
// the shell came from: the app's own bundle signs with its own.
func dropSigningConfigs(data []byte) []byte {
	s := string(data)
	key := strings.Index(s, `"signingConfigs"`)
	if key < 0 {
		return data
	}
	open := strings.Index(s[key:], "[")
	if open < 0 {
		return data
	}
	open += key
	depth := 0
	for j := open; j < len(s); j++ {
		switch s[j] {
		case '[':
			depth++
		case ']':
			depth--
			if depth != 0 {
				continue
			}
			start := strings.LastIndex(s[:key], "\n") + 1
			rest := strings.TrimLeft(s[j+1:], " \t")
			rest = strings.TrimPrefix(rest, ",")
			rest = strings.TrimPrefix(rest, "\r")
			rest = strings.TrimPrefix(rest, "\n")
			return []byte(s[:start] + rest)
		}
	}
	return data
}
