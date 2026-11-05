package pair

import (
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestIdleExpiresWithoutTouch(t *testing.T) {
	idle := NewIdle(30 * time.Millisecond)
	defer idle.Stop()
	select {
	case <-idle.Done():
	case <-time.After(time.Second):
		t.Fatal("idle did not expire")
	}
}

func TestIdleTouchExtendsDeadline(t *testing.T) {
	idle := NewIdle(80 * time.Millisecond)
	defer idle.Stop()
	deadline := time.Now().Add(200 * time.Millisecond)
	for time.Now().Before(deadline) {
		idle.Touch()
		time.Sleep(25 * time.Millisecond)
		select {
		case <-idle.Done():
			t.Fatal("idle expired while being touched")
		default:
		}
	}
	idle.Stop()
	select {
	case <-idle.Done():
		t.Fatal("Stop should not signal Done")
	case <-time.After(120 * time.Millisecond):
	}
}

func TestSuccessTouchesIdleFailuresDoNot(t *testing.T) {
	var touches atomic.Int32
	assign := &fakeAssigner{}
	handler := New(assign, func() { touches.Add(1) })

	if got := post(handler, `{`); got != 400 || touches.Load() != 0 {
		t.Fatalf("bad request: status=%d touches=%d", got, touches.Load())
	}
	assign.err = ErrUnauthorized
	if got := deletePeer(handler, testKey(1), "wrong"); got != 403 || touches.Load() != 0 {
		t.Fatalf("unauthorized: status=%d touches=%d", got, touches.Load())
	}
	assign.err = nil
	if got := post(handler, body(testKey(1))); got != 200 || touches.Load() != 1 {
		t.Fatalf("pair: status=%d touches=%d", got, touches.Load())
	}
	if got := deletePeer(handler, testKey(1), "credential"); got != 204 || touches.Load() != 2 {
		t.Fatalf("unpair: status=%d touches=%d", got, touches.Load())
	}

	unpairOnly := NewUnpairOnly(assign, func() { touches.Add(1) })
	if got := post(unpairOnly, body(testKey(2))); got != 405 || touches.Load() != 2 {
		t.Fatalf("unpair-only POST: status=%d touches=%d", got, touches.Load())
	}
	resp := httptest.NewRecorder()
	unpairOnly.ServeHTTP(resp, httptest.NewRequest("DELETE", "/v1/pair", strings.NewReader(`{"public_key":"`+testKey(2)+`","unpair_token":"credential"}`)))
	if resp.Code != 204 || touches.Load() != 3 {
		t.Fatalf("unpair-only DELETE: status=%d touches=%d", resp.Code, touches.Load())
	}
}
