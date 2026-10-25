//go:build linux || darwin

package bridge

import (
	"reflect"
	"syscall"
)

// freeSpace reports the bytes available to us under dir.
func freeSpace(dir string) (uint64, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, false
	}
	return st.Bavail * blockUnit(&st), true
}

// blockUnit is what Bavail counts in: f_frsize where there is one
// (Linux), else f_bsize.
func blockUnit(st *syscall.Statfs_t) uint64 {
	if fr := reflect.ValueOf(st).Elem().FieldByName("Frsize"); fr.IsValid() && fr.Int() > 0 {
		return uint64(fr.Int())
	}
	return uint64(st.Bsize)
}
