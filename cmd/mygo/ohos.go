package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// OpenHarmony (HarmonyOS) builds an app as a HAP: the Go code compiles to a
// c-archive, and a native shell of ArkTS and C++ loads it into the window it
// shows. MyGo's own package for the platform (internal/ohos) is what the app
// runs on; nothing of it appears in the app's code.

func runOhos(args []string) error {
	if len(args) == 0 {
		return ohosHelp()
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "build", "run", "init", "doctor":
	case "help", "-h", "--help":
		return ohosHelp()
	default:
		return fmt.Errorf("mygo ohos: no command %q (build, run, init, doctor)", cmd)
	}
	return ohosRun(cmd, rest)
}

func ohosHelp() error {
	fmt.Fprint(os.Stderr, `Builds a MyGo app for OpenHarmony (HarmonyOS) and runs it on a device.

Usage:

	mygo ohos <command> [flags] [dir]

Commands:

	init [dir]   make the HAP project of an app: the native shell of ArkTS and
	             C++ (NAPI, XComponent, IME overlay, host calls) that loads the
	             app's Go code, named after the app
	build [dir]  compile the app to libapp.a, then the HAP: signed if the HAP
	             project has signing material, a .hap in entry/build otherwise
	run [dir]    build, then install and start it on the connected device
	doctor       check the toolchain: a Go that builds for openharmony, the
	             native SDK, devecocli, and a device to run on

Flags (build, run, init):

	-hap dir     the HAP project (default: ../<app>-ohos, or the directory
	             holding it: one with entry/src/main/cpp/CMakeLists.txt)
	-go path     the Go toolchain built for openharmony (default: $OHOS_GO,
	             then go)
	-sdk dir     the native SDK (default: $OHOS_SDK, then the newest
	             ohos-sdk-native of homebrew)
	-bundle id   init: the app's bundle name
	-label name  init: the app's name

Run "mygo ohos doctor" when a build fails: it tells which piece is missing.
`)
	return nil
}

func ohosRun(cmd string, args []string) error {
	flags := newFlags("ohos "+cmd, "[flags] [dir]", "Builds a MyGo app for OpenHarmony (HarmonyOS).")
	hap := flags.String("hap", "", "the HAP project of the app")
	goTool := flags.String("go", "", "the Go toolchain built for openharmony")
	sdk := flags.String("sdk", "", "the OpenHarmony native SDK")
	bundle := flags.String("bundle", "", "the bundle name of init's HAP project")
	label := flags.String("label", "", "the app's name of init's HAP project")
	if err := flags.Parse(args); err != nil {
		return err
	}
	dir, err := ohosAppDir(flags.Args())
	if err != nil && cmd != "doctor" {
		return err
	}
	if cmd == "doctor" {
		return ohosDoctor(*goTool, *sdk)
	}
	g := ohosGo(*goTool)
	d := ohosSDK(*sdk)

	if cmd == "init" {
		dest := *hap
		if dest == "" {
			dest = filepath.Join(filepath.Dir(dir), filepath.Base(dir)+"-ohos")
		}
		name, app := *bundle, *label
		if name == "" {
			name = "com.example." + strings.ToLower(strings.NewReplacer("-", "", "_", "", " ", "").Replace(filepath.Base(dir)))
		}
		if app == "" {
			app = "MyGo"
		}
		return ohosInit(dest, name, app)
	}

	if g.err != nil {
		return g.err
	}
	if d.err != nil {
		return d.err
	}
	hapDir, err := ohosHapDir(*hap, dir)
	if err != nil {
		return err
	}

	fmt.Printf("== Go: c-archive for openharmony/arm64\n")
	lib, err := ohosArchive(dir, g.path, d)
	if err != nil {
		return err
	}
	fmt.Printf("== HAP: %s\n", hapDir)
	if err := ohosCopy(lib, filepath.Join(hapDir, "entry/src/main/cpp/libapp.a")); err != nil {
		return err
	}
	dev := "build"
	if cmd == "run" {
		dev = "run"
	}
	if err := ohosDevEco(hapDir, dev); err != nil {
		return err
	}
	if cmd == "run" {
		fmt.Printf("== running on the device\n")
	}
	return nil
}

// toolchain is a Go that knows openharmony, or why it does not.
type toolchain struct {
	path string
	err  error
}

func ohosGo(want string) toolchain {
	tries := []string{want, os.Getenv("OHOS_GO")}
	if home, err := os.UserHomeDir(); err == nil {
		tries = append(tries, filepath.Join(home, "Documents/MyProjects/ohos-go/bin/go"))
	}
	tries = append(tries, "go")
	for _, path := range tries {
		if path == "" {
			continue
		}
		if _, err := exec.LookPath(path); err != nil {
			continue
		}
		out, err := exec.Command(path, "tool", "dist", "list").Output()
		if err != nil {
			continue
		}
		if strings.Contains(string(out), "openharmony/arm64") {
			return toolchain{path: path}
		}
	}
	return toolchain{err: errors.New(`no Go builds for openharmony: make one from sysit/ohos-go (see docs/ohos-port.md), then set OHOS_GO to its bin/go or pass -go`)}
}

// sdk is the native SDK: clang, its sysroot and libc for aarch64-linux-ohos.
type sdk struct {
	dir   string
	clang string
	ar    string
	err   error
}

func ohosSDK(want string) sdk {
	tries := []string{want, os.Getenv("OHOS_SDK")}
	if home, err := os.UserHomeDir(); err == nil {
		matches, _ := filepath.Glob(filepath.Join(home, ".harmonybrew/Cellar/ohos-sdk-native/*"))
		sort.Strings(matches)
		for i := len(matches) - 1; i >= 0; i-- {
			tries = append(tries, matches[i])
		}
	}
	for _, dir := range tries {
		if dir == "" {
			continue
		}
		clang := filepath.Join(dir, "llvm/bin/clang")
		if _, err := os.Stat(clang); err != nil {
			continue
		}
		return sdk{dir: dir, clang: clang, ar: filepath.Join(dir, "llvm/bin/llvm-ar")}
	}
	return sdk{err: errors.New("no OpenHarmony native SDK: install the ohos-sdk-native homebrew cell, then set OHOS_SDK or pass -sdk")}
}

// ohosAppDir is the app's directory: where its go.mod is.
func ohosAppDir(args []string) (string, error) {
	dir := "."
	if len(args) > 0 {
		dir = args[0]
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(filepath.Join(abs, "go.mod")); err != nil {
		return "", fmt.Errorf("mygo ohos: %s is not a Go module (no go.mod)", abs)
	}
	return abs, nil
}

// ohosHapDir is the HAP project: what -hap names, or the sibling directory
// of the app that holds one.
func ohosHapDir(want, appDir string) (string, error) {
	const shell = "entry/src/main/cpp/CMakeLists.txt"
	if want != "" {
		abs, err := filepath.Abs(want)
		if err != nil {
			return "", err
		}
		if _, err := os.Stat(filepath.Join(abs, shell)); err != nil {
			return "", fmt.Errorf("mygo ohos: %s has no %s (is it a HAP project? mygo ohos init makes one)", abs, shell)
		}
		return abs, nil
	}
	var found []string
	patterns := []string{
		filepath.Join(filepath.Dir(appDir), "*"),
		filepath.Join(filepath.Dir(appDir), "*", "*"),
	}
	for _, pattern := range patterns {
		matches, _ := filepath.Glob(pattern)
		for _, m := range matches {
			if _, err := os.Stat(filepath.Join(m, shell)); err == nil {
				found = append(found, m)
			}
		}
	}
	switch len(found) {
	case 1:
		return found[0], nil
	case 0:
		return "", fmt.Errorf("mygo ohos: no HAP project next to %s: pass -hap, or make one with mygo ohos init", appDir)
	default:
		return "", fmt.Errorf("mygo ohos: several HAP projects next to %s (%s): pass -hap", appDir, strings.Join(found, ", "))
	}
}

// ohosArchive builds the app as the c-archive the HAP links.
func ohosArchive(appDir, goTool string, d sdk) (string, error) {
	lib := filepath.Join(appDir, "libapp.a")
	cc := fmt.Sprintf("%s --target=aarch64-linux-ohos --sysroot=%s/sysroot -D__MUSL__", d.clang, d.dir)
	cmd := exec.Command(goTool, "build", "-buildmode=c-archive", "-o", lib, ".")
	cmd.Dir = appDir
	cmd.Env = append(os.Environ(),
		"GOOS=openharmony", "GOARCH=arm64", "CGO_ENABLED=1",
		"GOTOOLCHAIN=local", "GOFLAGS=-mod=mod",
		"CC="+cc, "AR="+d.ar)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("go build: %w", err)
	}
	return lib, nil
}

// ohosDevEco builds the HAP, or builds, signs and installs it.
func ohosDevEco(hapDir, how string) error {
	cmd := exec.Command("devecocli", how)
	cmd.Dir = hapDir
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("devecocli %s: %w (mygo ohos doctor checks the tools)", how, err)
	}
	return nil
}

func ohosCopy(from, to string) error {
	data, err := os.ReadFile(from)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	return os.WriteFile(to, data, 0o644)
}

func ohosDoctor(goWant, sdkWant string) error {
	ok := true
	check := func(name string, good bool, detail string) {
		mark := "\033[32m✓\033[0m"
		if !good {
			mark, ok = "\033[31m✗\033[0m", false
		}
		fmt.Printf("%s %-10s %s\n", mark, name, detail)
	}
	g := ohosGo(goWant)
	detail := g.path
	if g.err != nil {
		detail = g.err.Error()
	} else if out, err := exec.Command(g.path, "version").Output(); err == nil {
		detail = strings.TrimSpace(string(out)) + " (" + g.path + ")"
	}
	check("go", g.err == nil, detail)

	d := ohosSDK(sdkWant)
	detail = d.dir
	if d.err != nil {
		detail = d.err.Error()
	}
	check("sdk", d.err == nil, detail)

	if path, err := exec.LookPath("devecocli"); err == nil {
		out, _ := exec.Command(path, "-V").CombinedOutput()
		check("devecocli", true, strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0]))
	} else {
		check("devecocli", false, "not found: it builds, signs and installs the HAP")
	}
	if out, err := exec.Command("devecocli", "device", "list").CombinedOutput(); err == nil {
		lines := strings.Split(strings.TrimSpace(string(out)), "\n")
		last := lines[len(lines)-1]
		check("device", len(lines) > 2, last)
	} else {
		check("device", false, "none connected, or devecocli cannot reach it")
	}
	if !ok {
		return errors.New("mygo ohos: the toolchain is not ready")
	}
	fmt.Println("The toolchain is ready: mygo ohos run <dir> builds and starts the app.")
	return nil
}
