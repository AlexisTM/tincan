//go:build !linux && !darwin

package bridge

func freeSpace(string) (uint64, bool) { return 0, false }
