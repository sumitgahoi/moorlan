package settings

import (
	"fmt"
	"os"
)

// Load reads Path and Parse-decodes it. Does not validate. Missing file
// suggests --setup.
func Load() (Site, error) {
	raw, err := os.ReadFile(Path)
	if err != nil {
		if os.IsNotExist(err) {
			return Site{}, fmt.Errorf("site conf %s not found; run: sudo moorlan --setup (or re-run install.sh); example: %s", Path, ExamplePath)
		}
		return Site{}, err
	}
	return Parse(raw)
}
