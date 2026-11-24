package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// The native shell of a HAP: the ArkTS page and its XComponents, the C++ that
// loads the app's Go code and passes it the window, the IME overlay, the
// subwindow page, and the HAP's own manifests. It is the same for every app,
// so it ships with the tool.
//
//go:embed all:shell
var shellFS embed.FS

// ohosInit writes the shell into dest and names it: bundle in the manifests,
// the app's name where the shell shows it, and no signing material, which
// belongs to the old bundle (devecocli signature generate makes the new one).
func ohosInit(dest, bundle, label string) error {
	if entries, err := os.ReadDir(dest); err == nil && len(entries) > 0 {
		return fmt.Errorf("mygo ohos init: %s is not empty", dest)
	}
	root, err := fs.Sub(shellFS, "shell")
	if err != nil {
		return err
	}
	files := 0
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
		case "app.json5", "module.json5":
			data = setJSONString(data, "bundleName", bundle)
		case "string.json":
			data = setJSONString(data, "value", label) // the shell's own name
		case "Index.ets":
			data = []byte(strings.ReplaceAll(string(data), "'MyGo'", "'"+label+"'"))
		case "build-profile.json5":
			data = dropSigningConfigs(data)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		files++
		return os.WriteFile(target, data, 0o644)
	})
	if err != nil {
		return err
	}
	fmt.Printf("== %s: the shell of a HAP project, %d files, %s (%s)\n", dest, files, bundle, label)
	fmt.Printf(`Next, once per bundle:

  cd %s && devecocli signature generate

then build and run the app:

  mygo ohos run <app dir> -hap %s
`, dest, dest)
	return nil
}

// setJSONString sets the value of the first "key": "value" of the JSON-ish
// manifests, which are JSON5: comments and trailing commas, which this
// leaves alone.
func setJSONString(data []byte, key, value string) []byte {
	pattern := regexp.MustCompile(`("` + regexp.QuoteMeta(key) + `"\s*:\s*")[^"]*(")`)
	return pattern.ReplaceAll(data, []byte("${1}"+value+"${2}"))
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

