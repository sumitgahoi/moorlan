package runtime

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
)

// LockInterface is held by main until process shutdown, so pairing and unjoin
// cannot race another PeerDoor process, even with different config paths/ports.
func LockInterface(name string) (func(), error) {
	if !validInterfaceName(name) {
		return nil, fmt.Errorf("invalid WireGuard interface name")
	}
	if runtime.GOOS != "linux" {
		return nil, fmt.Errorf("PeerDoor server requires Linux")
	}
	return lockFile(filepath.Join("/run", "peerdoor-"+name+".lock"))
}
func validInterfaceName(name string) bool {
	if len(name) == 0 || len(name) > 15 || name == "." || name == ".." {
		return false
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == '.') {
			return false
		}
	}
	return true
}
func lockFile(path string) (func(), error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, fmt.Errorf("another PeerDoor process is already using this interface: %w", err)
	}
	return func() { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN); _ = file.Close() }, nil
}
