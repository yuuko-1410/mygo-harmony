package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// OpenHarmony (HarmonyOS) builds an app as a HAP: the Go code compiles to a
// c-archive, and a native shell of ArkTS and C++ loads it into the window it
// shows. MyGo's own backend for the platform (internal/mobile, with an ArkTS
// host in internal/mobile/openharmony) is what the app runs on; nothing of it
// appears in the app's code.

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
		c, _ := loadConfig(dir)
		icon := ""
		if c != nil && c.Icon != "" {
			icon = c.path(c.Icon)
		}
		return ohosInit(dest, name, app, icon)
	}

	if err := ohosBuild(dir, *hap, g, d, cmd == "run"); err != nil {
		return err
	}
	return nil
}

// ohosBuild builds the app for OpenHarmony: its Go code as the c-archive the
// HAP links, then the HAP itself, into dist/ohos. It returns the HAP it built
// and made, or ran on the device.
func ohosBuild(appDir, hapFlag string, g toolchain, d sdk, run bool) error {
	if _, err := ohosHAP(appDir, hapFlag, g, d, run); err != nil {
		return err
	}
	if run {
		fmt.Printf("== running on the device\n")
	}
	return nil
}

// ohosHAP is ohosBuild's work, which mygo build and mygo ohos share: it
// writes the HAP project of the app, builds the app into it, builds the HAP
// and copies it to dist/ohos.
func ohosHAP(appDir, hapFlag string, g toolchain, d sdk, run bool) (string, error) {
	if g.err != nil {
		return "", g.err
	}
	if d.err != nil {
		return "", d.err
	}
	if err := ohosModule(appDir, g.path); err != nil {
		return "", err
	}
	hapDir, err := ohosHapDir(hapFlag, appDir)
	if err != nil {
		return "", err
	}
	if run {
		if err := ohosSign(hapDir); err != nil {
			return "", err
		}
	}
	t := con.start("Building for OpenHarmony")
	t.set("compiling Go")
	if _, err := ohosArchive(appDir, g.path, d); err != nil {
		return "", err
	}
	if err := ohosCopy(filepath.Join(appDir, ".mygo", "libapp.a"), filepath.Join(hapDir, "entry/src/main/cpp/libapp.a")); err != nil {
		return "", err
	}
	t.set("building the HAP (hvigor)")
	how := "build"
	if run {
		how = "run"
	}
	if err := ohosDevEco(hapDir, how); err != nil {
		return "", err
	}
	built, err := ohosOutput(hapDir)
	if err != nil {
		return "", err
	}
	c, err := loadConfig(appDir)
	if err != nil {
		return "", err
	}
	out := c.path(filepath.Join(c.Out, "ohos"))
	if err := os.MkdirAll(out, 0o755); err != nil {
		return "", err
	}
	dest := filepath.Join(out, c.slug()+"-"+c.Version+".hap")
	if err := ohosCopy(built, dest); err != nil {
		return "", err
	}
	if err := t.end(nil, "Built for OpenHarmony"); err != nil {
		return "", err
	}
	return dest, nil
}

// ohosOutput is the HAP hvigor wrote.
func ohosOutput(hapDir string) (string, error) {
	matches, _ := filepath.Glob(filepath.Join(hapDir, "entry/build/*/outputs/*/*.hap"))
	if len(matches) == 0 {
		matches, _ = filepath.Glob(filepath.Join(hapDir, "entry/build/*/*/*/*/*.hap"))
	}
	if len(matches) == 0 {
		return "", fmt.Errorf("mygo ohos: no HAP in %s (did hvigor build?)", hapDir)
	}
	sort.Slice(matches, func(i, j int) bool { return modTime(matches[i]) > modTime(matches[j]) })
	return matches[0], nil
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

// ohosHapDir is the HAP project: what -hap names, or the app's own, which the
// tool writes into .mygo/ohos as it writes Android's Gradle project into
// .mygo/android. A checked-in project, as mygo-ohos is, keeps its own.
func ohosHapDir(want, appDir string) (string, error) {
	if want != "" {
		abs, err := filepath.Abs(want)
		if err != nil {
			return "", err
		}
		if _, err := os.Stat(filepath.Join(abs, hapShell)); err != nil {
			return "", fmt.Errorf("mygo ohos: %s has no %s (is it a HAP project? mygo ohos init makes one)", abs, hapShell)
		}
		return abs, nil
	}
	c, err := loadConfig(appDir)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(appDir, ".mygo", "ohos")
	icon := ""
	if c.Icon != "" {
		icon = c.path(c.Icon)
	}
	if err := ohosWriteShell(dir, c.Identifier, c.Name, c.Version, icon); err != nil {
		return "", err
	}
	return dir, nil
}

// ohosModule checks that the app's MyGo is one with the OpenHarmony backend:
// a published release has none, so an app that requires one builds nothing
// for this platform.
func ohosModule(appDir, goTool string) error {
	cmd := exec.Command(goTool, "list", "-m", "-f", "{{.Dir}}", "github.com/egoist/mygo")
	cmd.Dir = appDir
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("mygo ohos: %s does not depend on MyGo: %w", appDir, err)
	}
	dir := strings.TrimSpace(string(out))
	if _, err := os.Stat(filepath.Join(dir, "internal/mobile/openharmony")); err == nil {
		return nil
	}
	fork := ohosSource()
	if fork == "" {
		fork = "<the checkout of MyGo with the OpenHarmony backend>"
	}
	return fmt.Errorf(`mygo ohos: the app's MyGo has no OpenHarmony backend: it resolves to %s

Point the app at the port, and tidy:

	cd %s
	go mod edit -replace github.com/egoist/mygo=%s
	go mod tidy

An app made by mygo init -mygo <that checkout> already points at it.`, dir, appDir, fork)
}

// ohosSource finds the checkout of MyGo the tool was built from, which is the
// one with the OpenHarmony backend: the tool sits in it, as go build -o mygo
// ./cmd/mygo makes it, or MYGO_SOURCE names it.
func ohosSource() string {
	has := func(dir string) bool {
		_, err := os.Stat(filepath.Join(dir, "internal/mobile/openharmony"))
		return err == nil
	}
	if src := os.Getenv("MYGO_SOURCE"); src != "" {
		if has(src) {
			return src
		}
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	dir := filepath.Dir(exe)
	for i := 0; i < 3; i++ {
		if has(dir) {
			return dir
		}
		dir = filepath.Dir(dir)
	}
	if wd, err := os.Getwd(); err == nil && has(wd) {
		return wd
	}
	return ""
}

// ohosArchive builds the app as the c-archive the HAP links, inside the
// app's .mygo, where builds keep their work: the app's own directory holds
// its source.
func ohosArchive(appDir, goTool string, d sdk) (string, error) {
	lib := filepath.Join(appDir, ".mygo", "libapp.a")
	if err := os.MkdirAll(filepath.Dir(lib), 0o755); err != nil {
		return "", err
	}
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

// buildOHOS builds the app for OpenHarmony, as mygo build does: a HAP in
// dist/ohos, signed when the project has signing material.
func buildOHOS(c *Config, o buildOptions) ([]string, error) {
	hap, err := ohosHAP(c.root, "", ohosGo(""), ohosSDK(""), false)
	if err != nil {
		return nil, err
	}
	return []string{hap}, nil
}

// ohosSign makes the signing material of the HAP project, once: devecocli
// binds it to the device, as Android's debug keystore is made once.
func ohosSign(hapDir string) error {
	profile := filepath.Join(hapDir, "build-profile.json5")
	data, err := os.ReadFile(profile)
	if err == nil && bytes.Contains(data, []byte(`"signingConfigs"`)) {
		return nil
	}
	fmt.Printf("== signing material: devecocli signature generate\n")
	cmd := exec.Command("devecocli", "signature", "generate")
	cmd.Dir = hapDir
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("devecocli signature generate: %w", err)
	}
	return nil
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

func modTime(path string) int64 {
	if info, err := os.Stat(path); err == nil {
		return info.ModTime().UnixNano()
	}
	return 0
}

// ohosDoctorLines tells what mygo doctor says of the OpenHarmony toolchain:
// it only warns, as a machine that builds for phones need not have it.
func ohosDoctorLines() []doctorLine {
	g := ohosGo("")
	if g.err != nil {
		return []doctorLine{{"ohos", false, "no Go that builds for openharmony (optional): see docs/ohos-port.md"}}
	}
	lines := []doctorLine{{"ohos", true, g.path}}
	d := ohosSDK("")
	if d.err != nil {
		lines = append(lines, doctorLine{"ohos-sdk", false, "no native SDK: install ohos-sdk-native, or set OHOS_SDK"})
		return lines
	}
	lines = append(lines, doctorLine{"ohos-sdk", true, d.dir})
	if path, err := exec.LookPath("devecocli"); err != nil {
		lines = append(lines, doctorLine{"devecocli", false, "not found: it builds, signs and installs the HAP"})
	} else {
		lines = append(lines, doctorLine{"devecocli", true, path})
	}
	return lines
}

// ohosHDC finds the device bridge of the OpenHarmony SDK, which installs a
// HAP and starts it: devecocli bundles one.
func ohosHDC() (string, error) {
	tries := []string{os.Getenv("OHOS_HDC")}
	if sdk := os.Getenv("DEVECO_SDK_HOME"); sdk != "" {
		tries = append(tries, filepath.Join(sdk, "default/openharmony/toolchains/hdc"))
	}
	tries = append(tries,
		"/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk/default/openharmony/toolchains/hdc")
	if d := os.Getenv("OHOS_SDK"); d != "" {
		tries = append(tries, filepath.Join(d, "toolchains/hdc"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		matches, _ := filepath.Glob(filepath.Join(home, ".harmonybrew/Cellar/ohos-sdk-native/*/toolchains/hdc"))
		tries = append(tries, matches...)
	}
	tries = append(tries, "hdc")
	for _, p := range tries {
		if p == "" {
			continue
		}
		if _, err := exec.LookPath(p); err == nil {
			return p, nil
		}
	}
	return "", errors.New("no hdc: it comes with the OpenHarmony SDK (set OHOS_HDC to it), and mygo dev installs the HAP with it")
}

// ohosRunTarget is the device mygo dev -platform ohos runs on: what -device
// names (its serial), else the only one connected.
func ohosRunTarget(want string) (*mobileDevice, error) {
	hdc, err := ohosHDC()
	if err != nil {
		return nil, err
	}
	out, err := exec.Command(hdc, "list", "targets").Output()
	if err != nil {
		return nil, fmt.Errorf("hdc list targets: %w", err)
	}
	var serials []string
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" && line != "[Empty]" {
			serials = append(serials, line)
		}
	}
	switch {
	case len(serials) == 0:
		return nil, errors.New("no OpenHarmony device connected (plug it in, or start the emulator)")
	case want != "":
		for _, serial := range serials {
			if serial == want {
				return &mobileDevice{platform: "ohos", id: serial, name: serial}, nil
			}
		}
		return nil, fmt.Errorf("no device %q: hdc lists %s", want, strings.Join(serials, ", "))
	case len(serials) > 1:
		return nil, fmt.Errorf("several devices (%s): -device picks one", strings.Join(serials, ", "))
	}
	return &mobileDevice{platform: "ohos", id: serials[0], name: serials[0]}, nil
}

// buildOhosDev builds the debug HAP of a dev session into stage, and returns
// its path, which launchOhos installs.
func (s *devSession) buildOhosDev(ctx context.Context, c, dc *Config, t *task, opts buildOptions, stage string) (string, error) {
	proj := filepath.Join(s.root, ".mygo", "dev", "ohos", "project")
	icon := ""
	if dc.Icon != "" {
		icon = c.path(dc.Icon)
	}
	if err := ohosWriteShell(proj, dc.Identifier, dc.Name, dc.Version, icon); err != nil {
		return "", err
	}
	if err := ohosSign(proj); err != nil {
		return "", err
	}
	t.set("compiling Go")
	g, d := ohosGo(""), ohosSDK("")
	if g.err != nil {
		return "", g.err
	}
	if d.err != nil {
		return "", d.err
	}
	if err := ohosModule(s.root, g.path); err != nil {
		return "", err
	}
	if _, err := ohosArchive(s.root, g.path, d); err != nil {
		return "", err
	}
	if err := ohosCopy(filepath.Join(s.root, ".mygo", "libapp.a"), filepath.Join(proj, "entry/src/main/cpp/libapp.a")); err != nil {
		return "", err
	}
	t.set("building the HAP (hvigor)")
	if err := ohosDevEco(proj, "build"); err != nil {
		return "", err
	}
	built, err := ohosOutput(proj)
	if err != nil {
		return "", err
	}
	dest := filepath.Join(stage, filepath.Base(built))
	return dest, ohosCopy(built, dest)
}

// launchOhos installs the HAP on the device, starts the app, and follows its
// log: hdc does the first two, devecocli the log, which it filters by bundle.
func (s *devSession) launchOhos(dc *Config, hap string, env []string) (*exec.Cmd, func(), error) {
	hdc, err := ohosHDC()
	if err != nil {
		return nil, nil, err
	}
	serial := s.device.id
	// An app running while its HAP is replaced keeps the window it had:
	// the files under it change, the surface it draws into is left with
	// none, and the window shows nothing or the app goes as it starts. It
	// stops first, and its window goes with it.
	exec.Command(hdc, "-t", serial, "shell", "aa", "force-stop", dc.Identifier).Run()
	// And gone before its files change: an app that is still going as its
	// HAP is installed over it has the window it had, and no surface to
	// draw into, which is a window of nothing, or a crash three seconds in.
	for i := 0; i < 20; i++ {
		out, err := exec.Command(hdc, "-t", serial, "shell", "pidof", dc.Identifier).Output()
		if err != nil || strings.TrimSpace(string(out)) == "" {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if out, err := exec.Command(hdc, "-t", serial, "install", "-r", hap).CombinedOutput(); err != nil {
		return nil, nil, fmt.Errorf("hdc install: %v\n%s", err, strings.TrimSpace(string(out)))
	}
	// The ability the shell has, which the app's shell always calls so.
	out, err := exec.Command(hdc, "-t", serial, "shell", "aa", "start",
		"-a", "EntryAbility", "-b", dc.Identifier, "--ps", "mygo.env", strings.Join(env, "\n")).CombinedOutput()
	if err != nil {
		return nil, nil, fmt.Errorf("hdc aa start: %v\n%s", err, strings.TrimSpace(string(out)))
	}
	cmd := exec.Command("devecocli", "log", "--follow", "--bundle-name", dc.Identifier)
	stop := func() {
		exec.Command(hdc, "-t", serial, "shell", "aa", "force-stop", dc.Identifier).Run()
	}
	return cmd, stop, nil
}
