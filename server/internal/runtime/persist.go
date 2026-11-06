package runtime

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"syscall"
)

// Linux iface names: start with a letter, then alnum/_/- ; IFNAMSIZ-1 = 15.
var ifaceName = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]{0,14}$`)

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

// ValidateInterfaceName requires a path-safe Linux interface name.
func ValidateInterfaceName(name string) error {
	return validateInterfaceName(name)
}

func validateInterfaceName(name string) error {
	if !ifaceName.MatchString(name) {
		return fmt.Errorf("invalid WireGuard interface name %q (use a Linux iface name such as wg0)", name)
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

// DefaultStorePath is the host-wide peer database.
const DefaultStorePath = "/var/lib/moorlan/moorlan.db"
