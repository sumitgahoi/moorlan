package runtime

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"syscall"
)

var moorlanIface = regexp.MustCompile(`^moorlan[0-9]+$`)

// LockInterface is held by main until process shutdown, so pairing and unpair
// cannot race another Moorlan process on the same device.
func LockInterface(name string) (func(), error) {
	if err := validateInterfaceName(name); err != nil {
		return nil, err
	}
	if runtime.GOOS != "linux" {
		return nil, fmt.Errorf("Moorlan server requires Linux")
	}
	return lockFile(filepath.Join("/run", "moorlan-"+name+".lock"))
}

func validateInterfaceName(name string) error {
	if !moorlanIface.MatchString(name) {
		return fmt.Errorf("WireGuard interface must be named moorlan0, moorlan1, … (got %q)", name)
	}
	if len(name) > 15 {
		return fmt.Errorf("WireGuard interface name too long")
	}
	return nil
}

func validInterfaceName(name string) bool {
	return validateInterfaceName(name) == nil
}

func lockFile(path string) (func(), error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, fmt.Errorf("another Moorlan process is already using this interface: %w", err)
	}
	return func() { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN); _ = file.Close() }, nil
}

// DefaultStorePath is /var/lib/moorlan/<iface>.db.
func DefaultStorePath(iface string) string {
	return filepath.Join("/var/lib/moorlan", iface+".db")
}
