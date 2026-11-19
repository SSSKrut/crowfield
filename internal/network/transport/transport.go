// Package transport moves encoded messages between a client and a server. A
// connection has ordered reliable channels for events and unreliable datagrams
// for input and snapshots. The same interface is implemented over QUIC, over
// memory for the embedded server, and by a network simulator over either.
//
// Sending never blocks: the server tick must not wait for a slow client.
// Datagram queues keep the newest datagrams, because a stale snapshot is worse
// than none. A reliable queue that overflows means the peer stopped reading, so
// SendReliable reports it and the caller should drop that peer.
package transport

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

type Channel uint8

const (
	ChannelControl Channel = iota
	ChannelEvents
	channelCount
)

const (
	// MaxDatagramSize fits one QUIC packet before path MTU discovery, so every
	// network path carries it. The snapshot budget of 1100 bytes stays below it.
	MaxDatagramSize = 1200
	MaxReliableSize = 64 << 10

	reliableQueueLimit        = 256
	datagramSendQueueLimit    = 16
	datagramReceiveQueueLimit = 128
)

var (
	ErrClosed         = errors.New("connection closed")
	ErrTooLarge       = errors.New("message is too large")
	ErrSendQueueFull  = errors.New("peer does not read its reliable messages")
	ErrListenerClosed = errors.New("listener closed")
	ErrUnknownChannel = errors.New("unknown channel")
)

// CloseError ends a connection. Remote is set when the peer closed it.
type CloseError struct {
	Reason string
	Remote bool
}

func (e *CloseError) Error() string {
	side := "locally"
	if e.Remote {
		side = "by the peer"
	}
	return fmt.Sprintf("connection closed %s: %s", side, e.Reason)
}

func (e *CloseError) Is(target error) bool {
	return target == ErrClosed
}

type Conn interface {
	// SendReliable queues a message on an ordered reliable channel.
	SendReliable(channel Channel, payload []byte) error
	// ReceiveReliable returns the next reliable message of any channel.
	// Messages of one channel arrive in the order they were sent.
	ReceiveReliable(ctx context.Context) (Channel, []byte, error)
	// SendUnreliable queues a datagram; when the queue is full the oldest
	// queued datagram is dropped.
	SendUnreliable(payload []byte) error
	ReceiveUnreliable(ctx context.Context) ([]byte, error)
	MaxUnreliableSize() int
	Stats() Stats
	// Close ends the connection at once and tells the peer the reason.
	// Messages still queued may be lost.
	Close(reason string) error
}

type Listener interface {
	Accept(ctx context.Context) (Conn, error)
	// Close stops accepting and ends every connection accepted from it.
	Close() error
	Addr() string
}

// Stats counts payloads, not transport overhead. DatagramsDropped counts the
// datagrams this side dropped: overflowing queues and simulated loss.
type Stats struct {
	RTT               time.Duration
	DatagramsSent     uint64
	DatagramsReceived uint64
	DatagramsDropped  uint64
	MessagesSent      uint64
	MessagesReceived  uint64
	BytesSent         uint64
	BytesReceived     uint64
}

type counters struct {
	datagramsSent, datagramsReceived, datagramsDropped atomic.Uint64
	messagesSent, messagesReceived                     atomic.Uint64
	bytesSent, bytesReceived                           atomic.Uint64
}

func (c *counters) stats(rtt time.Duration) Stats {
	return Stats{
		RTT: rtt, DatagramsSent: c.datagramsSent.Load(), DatagramsReceived: c.datagramsReceived.Load(),
		DatagramsDropped: c.datagramsDropped.Load(), MessagesSent: c.messagesSent.Load(),
		MessagesReceived: c.messagesReceived.Load(), BytesSent: c.bytesSent.Load(), BytesReceived: c.bytesReceived.Load(),
	}
}

func checkSend(channel Channel, payload []byte) error {
	if channel >= channelCount {
		return ErrUnknownChannel
	}
	if len(payload) > MaxReliableSize {
		return ErrTooLarge
	}
	return nil
}

type reliableMessage struct {
	channel Channel
	payload []byte
}

// queue is a mutex-protected FIFO with a wake-up signal. With a limit it drops
// its oldest item on overflow; without one it grows.
type queue[T any] struct {
	mu    sync.Mutex
	items []T
	limit int
	ready chan struct{}
}

func newQueue[T any](limit int) *queue[T] {
	return &queue[T]{limit: limit, ready: make(chan struct{}, 1)}
}

// push returns true when it dropped the oldest item to make room.
func (q *queue[T]) push(item T) bool {
	q.mu.Lock()
	dropped := q.limit > 0 && len(q.items) == q.limit
	if dropped {
		copy(q.items, q.items[1:])
		q.items = q.items[:len(q.items)-1]
	}
	q.items = append(q.items, item)
	q.mu.Unlock()
	select {
	case q.ready <- struct{}{}:
	default:
	}
	return dropped
}

func (q *queue[T]) tryPop() (T, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	var item T
	if len(q.items) == 0 {
		return item, false
	}
	item = q.items[0]
	var zero T
	copy(q.items, q.items[1:])
	q.items[len(q.items)-1] = zero
	q.items = q.items[:len(q.items)-1]
	return item, true
}

// pop waits for an item. It returns errDone when done closes first.
func (q *queue[T]) pop(ctx context.Context, done <-chan struct{}) (T, error) {
	for {
		if item, ok := q.tryPop(); ok {
			return item, nil
		}
		var zero T
		select {
		case <-q.ready:
		case <-ctx.Done():
			return zero, ctx.Err()
		case <-done:
			if item, ok := q.tryPop(); ok {
				return item, nil
			}
			return zero, errDone
		}
	}
}

var errDone = errors.New("done")
