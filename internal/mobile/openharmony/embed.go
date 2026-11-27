// Package openharmony holds the host of an app on OpenHarmony: the ArkTS
// pages and the module they import, and the C++ that loads the app's Go code
// and hands it the window. It is one copy, which mygo ohos init writes into
// the HAP project it makes, and which go generate keeps current with package
// wire: see README.md.
package openharmony

import "embed"

// Entry is the host's files, under the HAP's own entry directory: the pages,
// the module, the C++, and the module's declarations.
//
//go:embed entry/src/main/ets/mygo entry/src/main/ets/pages entry/src/main/cpp
var Entry embed.FS
