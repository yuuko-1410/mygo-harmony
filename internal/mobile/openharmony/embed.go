// Package openharmony holds the host of an app on OpenHarmony: the ArkTS
// page and its XComponents, and the C++ that loads the app's Go code and
// hands it the window. It is one copy, which mygo ohos init writes into the
// HAP project it makes (cmd/mygo), and which go generate keeps current with
// package wire: see README.md.
package openharmony

import "embed"

// Entry is the host's files, under the HAP's own entry directory: the pages
// and the module they import, the C++, and the module's declarations.
//
//go:embed entry
var Entry embed.FS
