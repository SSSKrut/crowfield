package transport

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
)

const (
	handshakeTimeout = 5 * time.Second
	closeCodeNormal  = 0
	closeCodeError   = 1
)

// QUICOptions tune a QUIC endpoint. WrapPacketConn, when set, wraps the UDP
// socket, for example with SimulatePackets.
type QUICOptions struct {
	WrapPacketConn func(net.PacketConn) net.PacketConn
}

func quicConfig() *quic.Config {
	return &quic.Config{
		EnableDatagrams:      true,
		HandshakeIdleTimeout: handshakeTimeout,
		MaxIdleTimeout:       10 * time.Second,
		KeepAlivePeriod:      2 * time.Second,
	}
}

// quicConn opens one bidirectional stream per channel. The client opens them
// right after the handshake and writes the channel number as the first byte,
// so the server can tell them apart.
type quicConn struct {
	conn       *quic.Conn
	packetConn net.PacketConn // owned by client connections only
	streams    [channelCount]*quic.Stream
	outgoing   [channelCount]chan []byte
	incoming   chan reliableMessage
	datagrams  *queue[[]byte]
	counters   counters
	closeOnce  sync.Once
}

func newQUICConn(conn *quic.Conn, streams [channelCount]*quic.Stream, packetConn net.PacketConn) *quicConn {
	c := &quicConn{
		conn: conn, packetConn: packetConn, streams: streams,
		incoming: make(chan reliableMessage, reliableQueueLimit), datagrams: newQueue[[]byte](datagramSendQueueLimit),
	}
	for channel := range channelCount {
		c.outgoing[channel] = make(chan []byte, reliableQueueLimit)
		go c.writeStream(channel)
		go c.readStream(channel)
	}
	go c.sendDatagrams()
	return c
}

func (c *quicConn) SendReliable(channel Channel, payload []byte) error {
	if err := c.closeErr(); err != nil {
		return err
	}
	if err := checkSend(channel, payload); err != nil {
		return err
	}
	frame := binary.AppendUvarint(make([]byte, 0, len(payload)+binary.MaxVarintLen32), uint64(len(payload)))
	select {
	case c.outgoing[channel] <- append(frame, payload...):
		c.counters.messagesSent.Add(1)
		c.counters.bytesSent.Add(uint64(len(payload)))
		return nil
	default:
		return ErrSendQueueFull
	}
}

func (c *quicConn) ReceiveReliable(ctx context.Context) (Channel, []byte, error) {
	select {
	case message := <-c.incoming:
		c.counters.messagesReceived.Add(1)
		c.counters.bytesReceived.Add(uint64(len(message.payload)))
		return message.channel, message.payload, nil
	case <-c.conn.Context().Done():
		return 0, nil, c.closeErr()
	case <-ctx.Done():
		return 0, nil, ctx.Err()
	}
}

func (c *quicConn) SendUnreliable(payload []byte) error {
	if err := c.closeErr(); err != nil {
		return err
	}
	if len(payload) > MaxDatagramSize {
		return ErrTooLarge
	}
	if c.datagrams.push(clone(payload)) {
		c.counters.datagramsDropped.Add(1)
	}
	return nil
}

func (c *quicConn) ReceiveUnreliable(ctx context.Context) ([]byte, error) {
	payload, err := c.conn.ReceiveDatagram(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, c.closeErr()
	}
	c.counters.datagramsReceived.Add(1)
	c.counters.bytesReceived.Add(uint64(len(payload)))
	return payload, nil
}

func (c *quicConn) MaxUnreliableSize() int {
	return MaxDatagramSize
}

func (c *quicConn) Stats() Stats {
	return c.counters.stats(c.conn.ConnectionStats().SmoothedRTT)
}

func (c *quicConn) Close(reason string) error {
	c.close(closeCodeNormal, reason)
	return nil
}

func (c *quicConn) close(code quic.ApplicationErrorCode, reason string) {
	c.closeOnce.Do(func() {
		_ = c.conn.CloseWithError(code, reason)
		if c.packetConn != nil {
			_ = c.packetConn.Close()
		}
	})
}

func (c *quicConn) closeErr() error {
	select {
	case <-c.conn.Context().Done():
		return closeError(context.Cause(c.conn.Context()))
	default:
		return nil
	}
}

// sendDatagrams runs SendDatagram, which blocks while QUIC congestion control
// holds packets back; meanwhile the queue in front of it keeps the newest.
func (c *quicConn) sendDatagrams() {
	for {
		payload, err := c.datagrams.pop(context.Background(), c.conn.Context().Done())
		if err != nil {
			return
		}
		if err := c.conn.SendDatagram(payload); err != nil {
			var tooLarge *quic.DatagramTooLargeError
			if !errors.As(err, &tooLarge) {
				return
			}
			c.counters.datagramsDropped.Add(1)
			continue
		}
		c.counters.datagramsSent.Add(1)
		c.counters.bytesSent.Add(uint64(len(payload)))
	}
}

func (c *quicConn) writeStream(channel Channel) {
	for {
		select {
		case frame := <-c.outgoing[channel]:
			if _, err := c.streams[channel].Write(frame); err != nil {
				return
			}
		case <-c.conn.Context().Done():
			return
		}
	}
}

func (c *quicConn) readStream(channel Channel) {
	reader := bufio.NewReader(c.streams[channel])
	for {
		length, err := binary.ReadUvarint(reader)
		if err != nil {
			return
		}
		if length > MaxReliableSize {
			c.close(closeCodeError, fmt.Sprintf("reliable message of %d bytes is too large", length))
			return
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return
		}
		select {
		case c.incoming <- reliableMessage{channel: channel, payload: payload}:
		case <-c.conn.Context().Done():
			return
		}
	}
}

func closeError(err error) error {
	var application *quic.ApplicationError
	if errors.As(err, &application) {
		return &CloseError{Reason: application.ErrorMessage, Remote: application.Remote}
	}
	var idle *quic.IdleTimeoutError
	if errors.As(err, &idle) {
		return &CloseError{Reason: "the peer stopped responding"}
	}
	return &CloseError{Reason: err.Error()}
}

// DialQUIC connects to a server. The connection owns its UDP socket.
func DialQUIC(ctx context.Context, address string, tlsConfig *tls.Config, options QUICOptions) (Conn, error) {
	remote, err := net.ResolveUDPAddr("udp", address)
	if err != nil {
		return nil, err
	}
	udp, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, err
	}
	packetConn := wrap(udp, options)
	conn, err := quic.Dial(ctx, packetConn, remote, tlsConfig, quicConfig())
	if err != nil {
		_ = packetConn.Close()
		return nil, err
	}
	var streams [channelCount]*quic.Stream
	for channel := range channelCount {
		stream, err := conn.OpenStreamSync(ctx)
		if err == nil {
			_, err = stream.Write([]byte{byte(channel)})
		}
		if err != nil {
			_ = conn.CloseWithError(closeCodeError, "could not open streams")
			_ = packetConn.Close()
			return nil, err
		}
		streams[channel] = stream
	}
	return newQUICConn(conn, streams, packetConn), nil
}

type quicListener struct {
	listener   *quic.Listener
	packetConn net.PacketConn
	ready      chan Conn
	ctx        context.Context
	cancel     context.CancelFunc
	closeOnce  sync.Once

	mu    sync.Mutex
	conns map[*quicConn]struct{}
}

// ListenQUIC accepts clients on a UDP address such as ":7777" or "127.0.0.1:0".
func ListenQUIC(address string, tlsConfig *tls.Config, options QUICOptions) (Listener, error) {
	local, err := net.ResolveUDPAddr("udp", address)
	if err != nil {
		return nil, err
	}
	udp, err := net.ListenUDP("udp", local)
	if err != nil {
		return nil, err
	}
	packetConn := wrap(udp, options)
	listener, err := quic.Listen(packetConn, tlsConfig, quicConfig())
	if err != nil {
		_ = packetConn.Close()
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	l := &quicListener{
		listener: listener, packetConn: packetConn, ready: make(chan Conn), ctx: ctx, cancel: cancel,
		conns: make(map[*quicConn]struct{}),
	}
	go l.acceptLoop()
	return l, nil
}

func (l *quicListener) acceptLoop() {
	for {
		conn, err := l.listener.Accept(l.ctx)
		if err != nil {
			return
		}
		go l.handshake(conn)
	}
}

// handshake waits for the channel streams of one client without holding up
// the others.
func (l *quicListener) handshake(conn *quic.Conn) {
	ctx, cancel := context.WithTimeout(l.ctx, handshakeTimeout)
	defer cancel()
	var streams [channelCount]*quic.Stream
	for range channelCount {
		stream, err := conn.AcceptStream(ctx)
		if err != nil {
			_ = conn.CloseWithError(closeCodeError, "channel streams were not opened")
			return
		}
		deadline, _ := ctx.Deadline()
		_ = stream.SetReadDeadline(deadline)
		var header [1]byte
		if _, err := io.ReadFull(stream, header[:]); err != nil || Channel(header[0]) >= channelCount || streams[header[0]] != nil {
			_ = conn.CloseWithError(closeCodeError, "bad channel stream")
			return
		}
		_ = stream.SetReadDeadline(time.Time{})
		streams[header[0]] = stream
	}
	c := newQUICConn(conn, streams, nil)
	if !l.track(c) {
		_ = c.Close("server is shutting down")
		return
	}
	select {
	case l.ready <- c:
	case <-l.ctx.Done():
		_ = c.Close("server is shutting down")
	}
}

// track remembers an accepted connection, so that Close can end it politely
// instead of leaving the client to time out.
func (l *quicListener) track(c *quicConn) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.ctx.Err() != nil {
		return false
	}
	l.conns[c] = struct{}{}
	go func() {
		<-c.conn.Context().Done()
		l.mu.Lock()
		delete(l.conns, c)
		l.mu.Unlock()
	}()
	return true
}

func (l *quicListener) Accept(ctx context.Context) (Conn, error) {
	select {
	case conn := <-l.ready:
		return conn, nil
	case <-l.ctx.Done():
		return nil, ErrListenerClosed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (l *quicListener) Close() error {
	l.closeOnce.Do(func() {
		l.mu.Lock()
		l.cancel()
		conns := make([]*quicConn, 0, len(l.conns))
		for c := range l.conns {
			conns = append(conns, c)
		}
		l.mu.Unlock()
		for _, c := range conns {
			_ = c.Close("server is shutting down")
		}
		_ = l.listener.Close()
		_ = l.packetConn.Close()
	})
	return nil
}

func (l *quicListener) Addr() string {
	return l.packetConn.LocalAddr().String()
}

func wrap(udp *net.UDPConn, options QUICOptions) net.PacketConn {
	if options.WrapPacketConn == nil {
		return udp
	}
	return options.WrapPacketConn(udp)
}
