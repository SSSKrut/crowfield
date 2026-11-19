package transport

import (
	"context"
	"sync"
)

// memoryLink is shared by both ends: closing either end closes the link.
type memoryLink struct {
	once   sync.Once
	closed chan struct{}
	reason string
	closer *memoryConn
}

// memoryConn is one end of an in-process connection, used by the embedded
// server. It still carries encoded bytes, so solo play runs the same protocol
// as network play.
type memoryConn struct {
	link      *memoryLink
	peer      *memoryConn
	reliable  chan reliableMessage
	datagrams *queue[[]byte]
	counters  counters
}

func NewMemoryPair() (Conn, Conn) {
	link := &memoryLink{closed: make(chan struct{})}
	first := newMemoryConn(link)
	second := newMemoryConn(link)
	first.peer, second.peer = second, first
	return first, second
}

func newMemoryConn(link *memoryLink) *memoryConn {
	return &memoryConn{
		link: link, reliable: make(chan reliableMessage, reliableQueueLimit),
		datagrams: newQueue[[]byte](datagramReceiveQueueLimit),
	}
}

func (c *memoryConn) SendReliable(channel Channel, payload []byte) error {
	if err := c.closeErr(); err != nil {
		return err
	}
	if err := checkSend(channel, payload); err != nil {
		return err
	}
	select {
	case c.peer.reliable <- reliableMessage{channel: channel, payload: clone(payload)}:
		c.counters.messagesSent.Add(1)
		c.counters.bytesSent.Add(uint64(len(payload)))
		return nil
	default:
		return ErrSendQueueFull
	}
}

func (c *memoryConn) ReceiveReliable(ctx context.Context) (Channel, []byte, error) {
	if err := c.closeErr(); err != nil {
		return 0, nil, err
	}
	select {
	case message := <-c.reliable:
		c.counters.messagesReceived.Add(1)
		c.counters.bytesReceived.Add(uint64(len(message.payload)))
		return message.channel, message.payload, nil
	case <-c.link.closed:
		return 0, nil, c.closeErr()
	case <-ctx.Done():
		return 0, nil, ctx.Err()
	}
}

func (c *memoryConn) SendUnreliable(payload []byte) error {
	if err := c.closeErr(); err != nil {
		return err
	}
	if len(payload) > MaxDatagramSize {
		return ErrTooLarge
	}
	if c.peer.datagrams.push(clone(payload)) {
		c.peer.counters.datagramsDropped.Add(1)
	}
	c.counters.datagramsSent.Add(1)
	c.counters.bytesSent.Add(uint64(len(payload)))
	return nil
}

func (c *memoryConn) ReceiveUnreliable(ctx context.Context) ([]byte, error) {
	if err := c.closeErr(); err != nil {
		return nil, err
	}
	payload, err := c.datagrams.pop(ctx, c.link.closed)
	if err == errDone {
		return nil, c.closeErr()
	}
	if err != nil {
		return nil, err
	}
	c.counters.datagramsReceived.Add(1)
	c.counters.bytesReceived.Add(uint64(len(payload)))
	return payload, nil
}

// MaxUnreliableSize matches QUIC, so what works in solo play works online.
func (c *memoryConn) MaxUnreliableSize() int {
	return MaxDatagramSize
}

func (c *memoryConn) Stats() Stats {
	return c.counters.stats(0)
}

func (c *memoryConn) Close(reason string) error {
	c.link.once.Do(func() {
		c.link.reason, c.link.closer = reason, c
		close(c.link.closed)
	})
	return nil
}

func (c *memoryConn) closeErr() error {
	select {
	case <-c.link.closed:
		return &CloseError{Reason: c.link.reason, Remote: c.link.closer != c}
	default:
		return nil
	}
}

// MemoryListener accepts in-process connections, so the server code accepts
// the embedded client the same way as network clients.
type MemoryListener struct {
	incoming chan Conn
	once     sync.Once
	closed   chan struct{}
}

func NewMemoryListener() *MemoryListener {
	return &MemoryListener{incoming: make(chan Conn, 16), closed: make(chan struct{})}
}

// Dial returns the client end of a new connection; the server end goes to Accept.
func (l *MemoryListener) Dial() (Conn, error) {
	client, server := NewMemoryPair()
	select {
	case <-l.closed:
		return nil, ErrListenerClosed
	default:
	}
	select {
	case l.incoming <- server:
		return client, nil
	default:
		return nil, ErrSendQueueFull
	}
}

func (l *MemoryListener) Accept(ctx context.Context) (Conn, error) {
	select {
	case conn := <-l.incoming:
		return conn, nil
	case <-l.closed:
		return nil, ErrListenerClosed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (l *MemoryListener) Close() error {
	l.once.Do(func() {
		close(l.closed)
		for {
			select {
			case conn := <-l.incoming:
				_ = conn.Close("server is shutting down")
			default:
				return
			}
		}
	})
	return nil
}

func (l *MemoryListener) Addr() string {
	return "memory"
}

func clone(payload []byte) []byte {
	return append([]byte(nil), payload...)
}
