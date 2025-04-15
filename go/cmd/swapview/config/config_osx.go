//go:build darwin

package config

import "os"

var Prefix = os.Getenv("HOME")
