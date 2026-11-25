//go:build openharmony || (linux && ohos)

package ohos

import (
	"encoding/json"
	"log"
	"sync"
)

// The form factor decides how windows behave: phones stack full-screen
// screens the way Android and iOS do, tablets and PCs open OS windows the
// way desktops do.
type formFactor int

const (
	formPhone formFactor = iota
	formTablet
	formDesktop
)

var (
	deviceOnce sync.Once
	deviceKind formFactor
	deviceName string
)

func readDevice() (formFactor, string) {
	deviceOnce.Do(func() {
		raw, err := callHost("device.info", nil)
		if err != nil || len(raw) == 0 {
			deviceKind, deviceName = formDesktop, "2in1"
			return
		}
		var out struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(raw, &out) != nil {
			deviceKind, deviceName = formDesktop, "2in1"
			return
		}
		deviceName = out.Type
		log.Printf("ohos: device %q", out.Type)
		switch out.Type {
		case "phone", "wearable":
			deviceKind = formPhone
		case "tablet", "tv":
			deviceKind = formTablet
		default:
			deviceKind = formDesktop
		}
	})
	return deviceKind, deviceName
}
