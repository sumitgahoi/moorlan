package pair

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type fakeAssigner struct {
	calls atomic.Int32
	err   error
}

func (f *fakeAssigner) Assign(context.Context, string, string) (Lease, error) {
	f.calls.Add(1)
	return Lease{Address: "10.8.0.2/32"}, f.err
}
func (f *fakeAssigner) Remove(context.Context, string, string) error { return f.err }
func testKey(value byte) string {
	raw := make([]byte, 32)
	raw[0] = value
	return base64.StdEncoding.EncodeToString(raw)
}
func body(key string) string { return `{"public_key":"` + key + `","label":"phone"}` }
func post(handler http.Handler, body string) int {
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("POST", "/v1/pair", strings.NewReader(body)))
	return response.Code
}
func deletePeer(handler http.Handler, key, credential string) int {
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("DELETE", "/v1/pair", strings.NewReader(`{"public_key":"`+key+`","unpair_token":"`+credential+`"}`)))
	return response.Code
}
func TestMultipleDevicesAndRetriesNeedNoInvitationToken(t *testing.T) {
	assign := &fakeAssigner{}
	handler := New(assign, Notify{})
	results := make(chan int, 2)
	for _, key := range []byte{1, 2} {
		go func(key byte) { results <- post(handler, body(testKey(key))) }(key)
	}
	for i := 0; i < 2; i++ {
		if status := <-results; status != 200 {
			t.Fatal(status)
		}
	}
	if status := post(handler, body(testKey(1))); status != 200 {
		t.Fatal(status)
	}
	if assign.calls.Load() != 3 {
		t.Fatal(assign.calls.Load())
	}
}
func TestAssignmentFailureCanBeRetried(t *testing.T) {
	assign := &fakeAssigner{err: errors.New("disk failure")}
	handler := New(assign, Notify{})
	if got := post(handler, body(testKey(1))); got != 500 {
		t.Fatal(got)
	}
	assign.err = nil
	if got := post(handler, body(testKey(1))); got != 200 {
		t.Fatal(got)
	}
}
func TestRejectMalformedAndOversizedRequests(t *testing.T) {
	assign := &fakeAssigner{}
	handler := New(assign, Notify{})
	for _, request := range []string{`{`, body(testKey(1)) + `{}`, `{"extra":true}`, body(testKey(0)), body(strings.Repeat("a", 5000)), `{"public_key":"` + testKey(1) + `"}`, `{"public_key":"` + testKey(1) + `","label":""}`} {
		if got := post(handler, request); got != 400 {
			t.Fatal(got)
		}
	}
	if assign.calls.Load() != 0 {
		t.Fatal("invalid request reached assignment")
	}
}
func TestUnpairCredentialsAndUnpairOnlyMode(t *testing.T) {
	assign := &fakeAssigner{}
	for _, handler := range []http.Handler{New(assign, Notify{}), NewUnpairOnly(assign, Notify{})} {
		if got := deletePeer(handler, testKey(1), "credential"); got != 204 {
			t.Fatal(got)
		}
		assign.err = ErrUnauthorized
		if got := deletePeer(handler, testKey(1), "wrong"); got != 403 {
			t.Fatal(got)
		}
		assign.err = errors.New("save failed")
		if got := deletePeer(handler, testKey(1), "credential"); got != 500 {
			t.Fatal(got)
		}
		assign.err = nil
		if got := deletePeer(handler, testKey(1), ""); got != 400 {
			t.Fatal(got)
		}
	}
	if got := post(NewUnpairOnly(assign, Notify{}), body(testKey(1))); got != 405 {
		t.Fatal(got)
	}
}
