//go:build openharmony || (linux && ohos)

package ohos

/*
#include <stdint.h>
void mygo_host_call(char *json);
*/
import "C"

import (
	"encoding/json"
	"errors"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// The host (ArkTS) answers what only it can do: the clipboard, dialogs,
// menus, notifications. Go asks with an id, the host replies with it.

type hostRequest struct {
	ID   int             `json:"id"`
	Op   string          `json:"op"`
	Args json.RawMessage `json:"args,omitempty"`
}

type hostReply struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

var (
	rpcMu      sync.Mutex
	rpcSeq     int
	rpcPending = map[int]chan hostReply{}
	// pumping tells that the main thread runs what the host asked for while
	// it waits for the host's answer.
	pumping bool
)

// hostTimeout is how long the host has to answer a call.
const hostTimeout = 10 * time.Second

// callHost asks the host to run op and waits for its reply.
func callHost(op string, args any) (json.RawMessage, error) {
	var raw json.RawMessage
	if args != nil {
		b, err := json.Marshal(args)
		if err != nil {
			return nil, err
		}
		raw = b
	}

	rpcMu.Lock()
	rpcSeq++
	id := rpcSeq
	ch := make(chan hostReply, 1)
	rpcPending[id] = ch
	rpcMu.Unlock()

	req := hostRequest{ID: id, Op: op, Args: raw}
	data, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	buf := append(data, 0)
	C.mygo_host_call((*C.char)(unsafe.Pointer(&buf[0])))

	reply, err := waitHost(id, ch, op)
	if err != nil {
		return nil, err
	}
	if reply.Error != "" {
		return nil, errors.New(reply.Error)
	}
	return reply.Result, nil
}

// waitHost waits for the host's answer, running what the host asked for
// meanwhile: a page's request for a custom scheme is served here, on the
// main thread, while its UI thread waits for the answer. Without it the two
// wait for each other, as the UI thread answers this call only once its
// page's request is served.
func waitHost(id int, ch chan hostReply, op string) (hostReply, error) {
	deadline := time.Now().Add(hostTimeout)
	for {
		select {
		case r := <-ch:
			return r, nil
		case <-time.After(2 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			rpcMu.Lock()
			delete(rpcPending, id)
			rpcMu.Unlock()
			return hostReply{}, errors.New("ohos: host did not answer " + op)
		}
		if b := current(); b != nil && b.onMainThread() && !pumping {
			b.pumpQueue()
		}
	}
}

// onMainThread tells whether the calling goroutine is the one that runs the
// loop, which alone serves a scheme request.
func (b *backend) onMainThread() bool {
	b.mu.Lock()
	tid := b.tid
	b.mu.Unlock()
	return tid != 0 && tid == unix.Gettid()
}

// pumpQueue runs what the loop has queued: the events of the host, and the
// requests of its pages, while the main thread waits for the host.
func (b *backend) pumpQueue() {
	pumping = true
	defer func() { pumping = false }()
	for i := 0; i < 64; i++ {
		b.mu.Lock()
		queue := b.queue
		b.queue = nil
		b.mu.Unlock()
		if len(queue) == 0 {
			return
		}
		for _, f := range queue {
			f()
		}
	}
}

//export mygo_host_reply
func mygo_host_reply(jsonPtr *C.char) {
	if jsonPtr == nil {
		return
	}
	var r hostReply
	if err := json.Unmarshal([]byte(C.GoString(jsonPtr)), &r); err != nil {
		return
	}
	rpcMu.Lock()
	ch := rpcPending[r.ID]
	delete(rpcPending, r.ID)
	rpcMu.Unlock()
	if ch != nil {
		ch <- r
	}
}
