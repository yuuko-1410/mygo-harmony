//go:build openharmony

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
)

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

	var reply hostReply
	select {
	case reply = <-ch:
	case <-time.After(5 * time.Second):
		rpcMu.Lock()
		delete(rpcPending, id)
		rpcMu.Unlock()
		return nil, errors.New("ohos: host did not answer " + op)
	}
	if reply.Error != "" {
		return nil, errors.New(reply.Error)
	}
	return reply.Result, nil
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
