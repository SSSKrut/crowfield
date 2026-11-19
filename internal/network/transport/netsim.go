package transport

import (
	"container/heap"
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// NetworkConditions describe a simulated network path. Delay is one way and
// applies in both directions, so the round trip gains 2 × (Delay + Jitter/2).
// Jitter adds a uniform extra delay in [0, Jitter), which also reorders
// datagrams. Loss and Duplicate are shares of datagrams, or of packets for
// SimulatePackets; reliable messages are only delayed and stay in order.
type NetworkConditions struct {
	Delay     time.Duration
	Jitter    time.Duration
	Loss      float64
	Duplicate float64
	Seed      uint64
}

// ParseNetworkConditions reads the -netsim flag format, for example
// "delay=50ms,jitter=10ms,loss=3%,dup=1%,seed=7". An empty string means none.
func ParseNetworkConditions(text string) (NetworkConditions, error) {
	var conditions NetworkConditions
	if strings.TrimSpace(text) == "" {
		return conditions, nil
	}
	for _, part := range strings.Split(text, ",") {
		key, value, found := strings.Cut(strings.TrimSpace(part), "=")
		if !found {
			return NetworkConditions{}, fmt.Errorf("network condition %q is not key=value", part)
		}
		var err error
		switch key {
		case "delay":
			conditions.Delay, err = time.ParseDuration(value)
		case "jitter":
			conditions.Jitter, err = time.ParseDuration(value)
		case "loss":
			conditions.Loss, err = parseShare(value)
		case "dup":
			conditions.Duplicate, err = parseShare(value)
		case "seed":
			conditions.Seed, err = strconv.ParseUint(value, 10, 64)
		default:
			return NetworkConditions{}, fmt.Errorf("unknown network condition %q", key)
		}
		if err != nil {
			return NetworkConditions{}, fmt.Errorf("network condition %s: %w", key, err)
		}
	}
	return conditions, conditions.Validate()
}

func (n NetworkConditions) Validate() error {
	switch {
	case n.Delay < 0 || n.Jitter < 0:
		return errors.New("delay and jitter must not be negative")
	case n.Loss < 0 || n.Loss >= 1:
		return errors.New("loss must be at least 0% and below 100%")
	case n.Duplicate < 0 || n.Duplicate > 1:
		return errors.New("duplication must be between 0% and 100%")
	}
	return nil
}

func (n NetworkConditions) String() string {
	return fmt.Sprintf("delay=%s,jitter=%s,loss=%g%%,dup=%g%%", n.Delay, n.Jitter, n.Loss*100, n.Duplicate*100)
}

func parseShare(value string) (float64, error) {
	if percent, ok := strings.CutSuffix(value, "%"); ok {
		share, err := strconv.ParseFloat(percent, 64)
		return share / 100, err
	}
	return strconv.ParseFloat(value, 64)
}

// Simulate wraps a connection with the given network conditions in both
// directions. It works over any Conn, including the in-memory one of solo play.
func Simulate(inner Conn, conditions NetworkConditions) Conn {
	ctx, cancel := context.WithCancel(context.Background())
	c := &simulatedConn{
		inner: inner, conditions: conditions, network: newNetwork(conditions),
		reliable: newQueue[reliableMessage](0), datagrams: newQueue[[]byte](datagramReceiveQueueLimit),
		failed: make(chan struct{}), ctx: ctx, cancel: cancel,
	}
	go c.receiveReliable()
	go c.receiveUnreliable()
	return c
}

type simulatedConn struct {
	inner      Conn
	conditions NetworkConditions
	network    *network
	reliable   *queue[reliableMessage]
	datagrams  *queue[[]byte]
	dropped    atomic.Uint64

	ctx      context.Context
	cancel   context.CancelFunc
	failOnce sync.Once
	failed   chan struct{}
	failure  error
}

func (c *simulatedConn) SendReliable(channel Channel, payload []byte) error {
	if err := c.failErr(); err != nil {
		return err
	}
	if err := checkSend(channel, payload); err != nil {
		return err
	}
	payload = clone(payload)
	c.network.sendOrdered(channel, func() {
		if err := c.inner.SendReliable(channel, payload); err != nil {
			c.fail(err)
		}
	})
	return nil
}

func (c *simulatedConn) ReceiveReliable(ctx context.Context) (Channel, []byte, error) {
	message, err := c.reliable.pop(ctx, c.failed)
	if err == errDone {
		return 0, nil, c.failure
	}
	return message.channel, message.payload, err
}

func (c *simulatedConn) SendUnreliable(payload []byte) error {
	if err := c.failErr(); err != nil {
		return err
	}
	if len(payload) > c.inner.MaxUnreliableSize() {
		return ErrTooLarge
	}
	payload = clone(payload)
	if !c.network.send(func() { _ = c.inner.SendUnreliable(payload) }) {
		c.dropped.Add(1)
	}
	return nil
}

func (c *simulatedConn) ReceiveUnreliable(ctx context.Context) ([]byte, error) {
	payload, err := c.datagrams.pop(ctx, c.failed)
	if err == errDone {
		return nil, c.failure
	}
	return payload, err
}

func (c *simulatedConn) MaxUnreliableSize() int {
	return c.inner.MaxUnreliableSize()
}

func (c *simulatedConn) Stats() Stats {
	stats := c.inner.Stats()
	stats.RTT += 2 * (c.conditions.Delay + c.conditions.Jitter/2)
	stats.DatagramsDropped += c.dropped.Load()
	return stats
}

func (c *simulatedConn) Close(reason string) error {
	c.fail(&CloseError{Reason: reason})
	c.cancel()
	c.network.stop()
	return c.inner.Close(reason)
}

func (c *simulatedConn) receiveReliable() {
	for {
		channel, payload, err := c.inner.ReceiveReliable(c.ctx)
		if err != nil {
			c.network.after(func() { c.fail(err) })
			return
		}
		c.network.receiveOrdered(channel, func() { c.reliable.push(reliableMessage{channel: channel, payload: payload}) })
	}
}

func (c *simulatedConn) receiveUnreliable() {
	for {
		payload, err := c.inner.ReceiveUnreliable(c.ctx)
		if err != nil {
			return
		}
		if !c.network.send(func() { c.datagrams.push(payload) }) {
			c.dropped.Add(1)
		}
	}
}

func (c *simulatedConn) fail(err error) {
	c.failOnce.Do(func() {
		c.failure = err
		close(c.failed)
	})
}

func (c *simulatedConn) failErr() error {
	select {
	case <-c.failed:
		return c.failure
	default:
		return nil
	}
}

// SimulatePackets applies the conditions to the packets a UDP socket writes.
// Wrap the sockets of both endpoints to affect both directions.
func SimulatePackets(conn net.PacketConn, conditions NetworkConditions) net.PacketConn {
	return &simulatedPacketConn{PacketConn: conn, network: newNetwork(conditions)}
}

type simulatedPacketConn struct {
	net.PacketConn
	network *network
}

func (c *simulatedPacketConn) WriteTo(packet []byte, address net.Addr) (int, error) {
	packet = clone(packet)
	c.network.send(func() { _, _ = c.PacketConn.WriteTo(packet, address) })
	return len(packet), nil
}

// Close first lets scheduled packets go out: QUIC hands over its connection
// close packet just before the socket closes, and the peer must still get it.
func (c *simulatedPacketConn) Close() error {
	c.network.drain()
	return c.PacketConn.Close()
}

// SetReadBuffer and SetWriteBuffer let quic-go enlarge the socket buffers.
func (c *simulatedPacketConn) SetReadBuffer(bytes int) error {
	if conn, ok := c.PacketConn.(interface{ SetReadBuffer(int) error }); ok {
		return conn.SetReadBuffer(bytes)
	}
	return nil
}

func (c *simulatedPacketConn) SetWriteBuffer(bytes int) error {
	if conn, ok := c.PacketConn.(interface{ SetWriteBuffer(int) error }); ok {
		return conn.SetWriteBuffer(bytes)
	}
	return nil
}

// network schedules deliveries with delay, jitter, loss and duplication. One
// goroutine runs every delivery in time order.
type network struct {
	conditions NetworkConditions

	mu          sync.Mutex
	random      *rand.Rand
	events      eventHeap
	sequence    uint64
	pending     int
	lastOrdered [2 * channelCount]time.Time
	closing     bool
	stopped     bool

	wake chan struct{}
	done chan struct{}
}

func newNetwork(conditions NetworkConditions) *network {
	seed := conditions.Seed
	if seed == 0 {
		seed = rand.Uint64()
	}
	n := &network{
		conditions: conditions, random: rand.New(rand.NewPCG(seed, seed^0x9E3779B97F4A7C15)),
		wake: make(chan struct{}, 1), done: make(chan struct{}),
	}
	go n.run()
	return n
}

// send schedules an unreliable delivery. It returns false when it was lost.
func (n *network) send(deliver func()) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.random.Float64() < n.conditions.Loss {
		return false
	}
	n.scheduleLocked(time.Now().Add(n.delayLocked()), deliver)
	if n.random.Float64() < n.conditions.Duplicate {
		n.scheduleLocked(time.Now().Add(n.delayLocked()), deliver)
	}
	return true
}

func (n *network) sendOrdered(channel Channel, deliver func()) {
	n.ordered(int(channel), deliver)
}

func (n *network) receiveOrdered(channel Channel, deliver func()) {
	n.ordered(int(channelCount+channel), deliver)
}

// ordered delays a reliable message but never before an earlier one of the
// same direction and channel.
func (n *network) ordered(lane int, deliver func()) {
	n.mu.Lock()
	defer n.mu.Unlock()
	at := time.Now().Add(n.delayLocked())
	if at.Before(n.lastOrdered[lane]) {
		at = n.lastOrdered[lane]
	}
	n.lastOrdered[lane] = at
	n.scheduleLocked(at, deliver)
}

// after runs deliver once everything scheduled so far has been delivered.
func (n *network) after(deliver func()) {
	n.mu.Lock()
	defer n.mu.Unlock()
	at := time.Now().Add(n.conditions.Delay + n.conditions.Jitter)
	for _, last := range n.lastOrdered {
		if at.Before(last) {
			at = last
		}
	}
	n.scheduleLocked(at, deliver)
}

func (n *network) delayLocked() time.Duration {
	delay := n.conditions.Delay
	if n.conditions.Jitter > 0 {
		delay += time.Duration(n.random.Int64N(int64(n.conditions.Jitter)))
	}
	return delay
}

func (n *network) scheduleLocked(at time.Time, deliver func()) {
	if n.stopped || n.closing {
		return
	}
	n.pending++
	n.sequence++
	heap.Push(&n.events, event{at: at, sequence: n.sequence, deliver: deliver})
	select {
	case n.wake <- struct{}{}:
	default:
	}
}

// drain refuses new deliveries, waits for the scheduled ones and stops.
func (n *network) drain() {
	n.mu.Lock()
	n.closing = true
	n.mu.Unlock()
	deadline := time.Now().Add(n.conditions.Delay + n.conditions.Jitter + 100*time.Millisecond)
	for time.Now().Before(deadline) {
		n.mu.Lock()
		pending := n.pending
		n.mu.Unlock()
		if pending == 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	n.stop()
}

func (n *network) stop() {
	n.mu.Lock()
	defer n.mu.Unlock()
	if !n.stopped {
		n.stopped = true
		close(n.done)
	}
}

func (n *network) run() {
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()
	var due []event
	for {
		n.mu.Lock()
		now := time.Now()
		due = due[:0]
		for len(n.events) > 0 && !n.events[0].at.After(now) {
			due = append(due, heap.Pop(&n.events).(event))
		}
		wait := time.Hour
		if len(n.events) > 0 {
			wait = n.events[0].at.Sub(now)
		}
		n.mu.Unlock()
		for _, e := range due {
			e.deliver()
		}
		n.mu.Lock()
		n.pending -= len(due)
		n.mu.Unlock()
		timer.Reset(wait)
		select {
		case <-timer.C:
		case <-n.wake:
		case <-n.done:
			return
		}
	}
}

type event struct {
	at       time.Time
	sequence uint64
	deliver  func()
}

type eventHeap []event

func (h eventHeap) Len() int { return len(h) }

func (h eventHeap) Less(i, j int) bool {
	if h[i].at.Equal(h[j].at) {
		return h[i].sequence < h[j].sequence
	}
	return h[i].at.Before(h[j].at)
}

func (h eventHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }

func (h *eventHeap) Push(value any) { *h = append(*h, value.(event)) }

func (h *eventHeap) Pop() any {
	old := *h
	last := old[len(old)-1]
	old[len(old)-1] = event{}
	*h = old[:len(old)-1]
	return last
}
