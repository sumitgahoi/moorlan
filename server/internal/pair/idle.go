package pair

import (
	"sync"
	"time"
)

// DefaultIdle is how long --pair / --unpair stay up with no successful mutation.
const DefaultIdle = 2 * time.Minute

// Idle closes Done after dur with no Touch. Touch is meant for successful
// enroll/unpair only so probes cannot keep the session open.
type Idle struct {
	touch   chan struct{}
	done    chan struct{}
	stop    chan struct{}
	stopped sync.Once
}

func NewIdle(dur time.Duration) *Idle {
	if dur <= 0 {
		dur = DefaultIdle
	}
	i := &Idle{
		touch: make(chan struct{}, 1),
		done:  make(chan struct{}),
		stop:  make(chan struct{}),
	}
	go i.loop(dur)
	return i
}

func (i *Idle) Touch() {
	select {
	case i.touch <- struct{}{}:
	default:
	}
}

func (i *Idle) Done() <-chan struct{} { return i.done }

// Stop cancels the idle timer without signaling Done (e.g. after Ctrl-C).
func (i *Idle) Stop() {
	i.stopped.Do(func() { close(i.stop) })
}

func (i *Idle) loop(dur time.Duration) {
	timer := time.NewTimer(dur)
	defer timer.Stop()
	for {
		select {
		case <-i.stop:
			return
		case <-i.touch:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(dur)
		case <-timer.C:
			close(i.done)
			return
		}
	}
}
