package qr

import (
	"fmt"
	"io"

	qrcode "github.com/skip2/go-qrcode"
)

// WriteANSI prints a terminal-scannable QR for text.
func WriteANSI(w io.Writer, text string) error {
	code, err := qrcode.New(text, qrcode.Medium)
	if err != nil {
		return err
	}
	_, err = fmt.Fprint(w, code.ToSmallString(false))
	return err
}
