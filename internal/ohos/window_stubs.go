//go:build openharmony || (linux && ohos)

// Code generated from internal/platform/platform.go for Window -- do not edit by hand.

package ohos

import (
	"github.com/egoist/mygo/internal/platform"
)




func (w *window) CapturePage(cb func(png []byte, err error)) {
}

func (w *window) CaptureState(kind platform.CaptureKind) platform.CaptureState {
	return platform.CaptureNone
}

func (w *window) CloseDevTools() {
}

func (w *window) DroppedFiles() []string {
	return nil
}


func (w *window) FlashFrame(flash bool) {
}

func (w *window) GPUProcessID() int {
	return 0
}



func (w *window) HasShadow() bool {
	return false
}

func (w *window) IgnoresMouseEvents() bool {
	return false
}

func (w *window) IsAlwaysOnTop() bool {
	return false
}

func (w *window) IsAudible() bool {
	return false
}

func (w *window) IsAudioMuted() bool {
	return false
}

func (w *window) IsClosable() bool {
	return false
}

func (w *window) IsDevToolsOpened() bool {
	return false
}


func (w *window) IsMaximizable() bool {
	return false
}

func (w *window) IsMinimizable() bool {
	return false
}

func (w *window) IsMovable() bool {
	return false
}




func (w *window) OpenDevTools() {
}

func (w *window) PictureInPictureActive(cb func(active bool)) {
}

func (w *window) PlaceFlyout(f platform.Flyout, size platform.Size) {
}

func (w *window) Print() {
}

func (w *window) PrintToPDF(opts platform.PDFOptions, cb func(pdf []byte, err error)) {
}

func (w *window) ProcessID() int {
	return 0
}


func (w *window) Restore() {
}

func (w *window) RestoreSessionState(state []byte) bool {
	return false
}

func (w *window) SessionState() []byte {
	return nil
}

func (w *window) SetActiveAppearance(v bool) {
}

func (w *window) SetAlwaysOnTop(v bool) {
}

func (w *window) SetAudioMuted(muted bool) {
}

func (w *window) SetAutoHideMenu(v bool) {
}

func (w *window) SetCaptureState(kind platform.CaptureKind, state platform.CaptureState) {
}

func (w *window) SetClosable(v bool) {
}

func (w *window) SetContentProtection(v bool) {
}


func (w *window) SetDocumentEdited(edited bool) {
}

func (w *window) SetHasShadow(v bool) {
}

func (w *window) SetIcon(png []byte) error {
	return platform.Unsupported("ohos: not supported")
}

func (w *window) SetIgnoreMouseEvents(v bool) {
}

func (w *window) SetMaximizable(v bool) {
}

func (w *window) SetMaximumSize(s platform.Size) {
}

func (w *window) SetMenu(m *platform.Menu) {
}

func (w *window) SetMinimizable(v bool) {
}

func (w *window) SetMinimumSize(s platform.Size) {
}

func (w *window) SetMovable(v bool) {
}

func (w *window) SetProgressBar(state string, value float64) {
}

func (w *window) SetRepresentedFile(path string) {
}

func (w *window) SetSkipTaskbar(v bool) {
}



func (w *window) SetVibrancy(material string) {
}

func (w *window) SetVibrancyTint(c *platform.Color) {
}

func (w *window) SetVisibleOnAllWorkspaces(v bool) {
}

func (w *window) SetWindowButtonsTheme(source string) {
}


func (w *window) StartDrag() {
}


func (w *window) TitleBar() platform.TitleBar {
	return platform.TitleBar{}
}

func (w *window) TitleBarDoubleClicked() {
}

func (w *window) TogglePictureInPicture() {
}


func (w *window) Unmaximize() {
}



