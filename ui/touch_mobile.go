//go:build ios || android || js || openharmony

package ui

// Phones and tablets have touch screens, and browsers run on them.
func init() { enableTouch() }
