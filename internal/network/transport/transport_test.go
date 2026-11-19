package transport

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"
)

type pairFactory func(t *testing.T) (client, server Conn)

// Light conditions keep these tests fast; TestNetworkConditions covers the
// heavy ones from the plan.
var light = NetworkConditions{Delay: 5 * time.Millisecond, Jitter: 2 * time.Millisecond, Seed: 1}

func transports() map[string]pairFactory {
	return map[string]pairFactory{
		"memory": func(t *testing.T) (Conn, Conn) { return newMemoryPair(t) },
		"quic":   func(t *testing.T) (Conn, Conn) { return newQUICPair(t, QUICOptions{}, QUICOptions{}) },
		"memory+netsim": func(t *testing.T) (Conn, Conn) {
			client, server := newMemoryPair(t)
			return simulate(t, client, light), server
		},
		"quic+netsim": func(t *testing.T) (Conn, Conn) {
			return newQUICPair(t, packetSimulation(light), packetSimulation(light))
		},
	}
}

func TestReliableMessagesKeepOrderPerChannel(t *testing.T) {
	// Fewer messages than the reliable queue holds, since nobody reads while sending.
	const messages = 200
	for name, pair := range transports() {
		t.Run(name, func(t *testing.T) {
			client, server := pair(t)
			for _, direction := range [][2]Conn{{client, server}, {server, client}} {
				sender, receiver := direction[0], direction[1]
				buffer := make([]byte, 0, 64)
				for i := range messages {
					buffer = fmt.Appendf(buffer[:0], "%d:%d", i%2, i)
					if err := sender.SendReliable(Channel(i%2), buffer); err != nil {
						t.Fatal(err)
					}
				}
				var last [channelCount]int
				last[0], last[1] = -2, -1
				for range messages {
					channel, payload := receiveReliable(t, receiver)
					var lane, index int
					if _, err := fmt.Sscanf(string(payload), "%d:%d", &lane, &index); err != nil || Channel(lane) != channel {
						t.Fatalf("message %q arrived on channel %d", payload, channel)
					}
					if index != last[channel]+2 {
						t.Fatalf("channel %d: message %d after %d", channel, index, last[channel])
					}
					last[channel] = index
				}
			}
			if stats := server.Stats(); stats.MessagesReceived != messages || stats.MessagesSent != messages {
				t.Errorf("server stats %+v", stats)
			}
		})
	}
}

func TestDatagramsArrive(t *testing.T) {
	for name, pair := range transports() {
		t.Run(name, func(t *testing.T) {
			client, server := pair(t)
			want := make(map[string]bool)
			for i := range 50 {
				size := 1 + i*(client.MaxUnreliableSize()-1)/49
				payload := bytes.Repeat([]byte{byte(i)}, size)
				want[string(payload)] = true
				if err := client.SendUnreliable(payload); err != nil {
					t.Fatal(err)
				}
				time.Sleep(time.Millisecond)
			}
			for len(want) > 0 {
				payload := receiveUnreliable(t, server)
				if !want[string(payload)] {
					t.Fatalf("unexpected or repeated datagram of %d bytes", len(payload))
				}
				delete(want, string(payload))
			}
		})
	}
}

func TestOversizedSendsFail(t *testing.T) {
	for name, pair := range transports() {
		t.Run(name, func(t *testing.T) {
			client, _ := pair(t)
			if err := client.SendUnreliable(make([]byte, client.MaxUnreliableSize()+1)); !errors.Is(err, ErrTooLarge) {
				t.Errorf("oversized datagram: %v", err)
			}
			if err := client.SendReliable(ChannelControl, make([]byte, MaxReliableSize+1)); !errors.Is(err, ErrTooLarge) {
				t.Errorf("oversized message: %v", err)
			}
			if err := client.SendReliable(channelCount, nil); !errors.Is(err, ErrUnknownChannel) {
				t.Errorf("unknown channel: %v", err)
			}
		})
	}
}

// A peer that stops reading must not stall the sender: datagrams drop and the
// reliable queue reports that it is full.
func TestSendingToAStalledPeerNeverBlocks(t *testing.T) {
	for name, pair := range transports() {
		t.Run(name, func(t *testing.T) {
			client, _ := pair(t)
			started := time.Now()
			for range 5000 {
				if err := client.SendUnreliable(make([]byte, 1000)); err != nil {
					t.Fatal(err)
				}
			}
			payload := make([]byte, 8<<10)
			full := false
			for range 20000 {
				err := client.SendReliable(ChannelEvents, payload)
				if errors.Is(err, ErrSendQueueFull) {
					full = true
					break
				}
				if err != nil {
					t.Fatal(err)
				}
			}
			if !full {
				t.Error("the reliable queue never filled up")
			}
			if elapsed := time.Since(started); elapsed > 3*time.Second {
				t.Errorf("sending took %s", elapsed)
			}
		})
	}
}

func TestCloseTellsThePeer(t *testing.T) {
	for name, pair := range transports() {
		t.Run(name, func(t *testing.T) {
			client, server := pair(t)
			// Make sure the connection is fully up before closing it.
			if err := client.SendReliable(ChannelControl, []byte("hello")); err != nil {
				t.Fatal(err)
			}
			receiveReliable(t, server)
			if err := client.Close("bye"); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, _, err := server.ReceiveReliable(ctx)
			var closed *CloseError
			if !errors.As(err, &closed) || closed.Reason != "bye" || !closed.Remote || !errors.Is(err, ErrClosed) {
				t.Errorf("server saw %v", err)
			}
			if _, err := client.ReceiveUnreliable(ctx); !errors.As(err, &closed) || closed.Remote {
				t.Errorf("client saw %v", err)
			}
			if err := client.SendReliable(ChannelControl, nil); !errors.Is(err, ErrClosed) {
				t.Errorf("sending after close: %v", err)
			}
		})
	}
}

func TestServerCloseReachesSimulatedClient(t *testing.T) {
	client, server := newMemoryPair(t)
	simulated := simulate(t, client, NetworkConditions{Delay: 30 * time.Millisecond, Seed: 2})
	if err := server.SendReliable(ChannelEvents, []byte("last words")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
	_ = server.Close("kicked")
	if _, payload := receiveReliable(t, simulated); string(payload) != "last words" {
		t.Errorf("got %q before the close", payload)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, _, err := simulated.ReceiveReliable(ctx)
	var closed *CloseError
	if !errors.As(err, &closed) || closed.Reason != "kicked" || !closed.Remote {
		t.Errorf("client saw %v", err)
	}
}

// The check of step 1.3: 100 ms delay, 20 ms jitter and 5 % loss.
func TestNetworkConditions(t *testing.T) {
	heavy := NetworkConditions{Delay: 100 * time.Millisecond, Jitter: 20 * time.Millisecond, Loss: 0.05, Seed: 7}
	t.Run("memory", func(t *testing.T) {
		client, server := newMemoryPair(t)
		simulated := simulate(t, client, heavy)
		checkReliableUnderConditions(t, simulated, server, heavy.Delay)
		checkDatagramsUnderConditions(t, simulated, server, heavy)
		checkDatagramsUnderConditions(t, server, simulated, heavy)
		if rtt := simulated.Stats().RTT; rtt != 220*time.Millisecond {
			t.Errorf("simulated RTT %s, want 220ms", rtt)
		}
	})
	t.Run("quic packets", func(t *testing.T) {
		// Each socket delays its own packets, so the one-way delay is that of one socket.
		client, server := newQUICPair(t, packetSimulation(heavy), packetSimulation(heavy))
		checkReliableUnderConditions(t, client, server, heavy.Delay)
		checkDatagramsUnderConditions(t, client, server, heavy)
		rtt := client.Stats().RTT
		if rtt < 2*heavy.Delay || rtt > 2*(heavy.Delay+heavy.Jitter)+100*time.Millisecond {
			t.Errorf("QUIC measured RTT %s", rtt)
		}
		t.Logf("QUIC measured RTT %s", rtt)
	})
	t.Run("duplication", func(t *testing.T) {
		client, server := newMemoryPair(t)
		simulated := simulate(t, client, NetworkConditions{Duplicate: 0.5, Seed: 3})
		received := 0
		done := make(chan struct{})
		go func() {
			defer close(done)
			ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cancel()
			for {
				if _, err := server.ReceiveUnreliable(ctx); err != nil {
					return
				}
				received++
			}
		}()
		for i := range 200 {
			_ = simulated.SendUnreliable([]byte{byte(i)})
			time.Sleep(100 * time.Microsecond)
		}
		<-done
		if received < 250 || received > 350 {
			t.Errorf("50%% duplication turned 200 datagrams into %d", received)
		}
	})
}

// checkReliableUnderConditions sends timestamped messages: all must arrive, in
// order, and none sooner than the one-way delay.
func checkReliableUnderConditions(t *testing.T, sender, receiver Conn, delay time.Duration) {
	t.Helper()
	for i := range 100 {
		payload := binary.AppendVarint(binary.AppendUvarint(nil, uint64(i)), time.Now().UnixNano())
		if err := sender.SendReliable(ChannelEvents, payload); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Millisecond)
	}
	for i := range 100 {
		_, payload := receiveReliable(t, receiver)
		index, n := binary.Uvarint(payload)
		sent, _ := binary.Varint(payload[n:])
		if int(index) != i {
			t.Fatalf("reliable message %d arrived as number %d", index, i)
		}
		if latency := time.Since(time.Unix(0, sent)); latency < delay {
			t.Fatalf("reliable message %d arrived after %s, sooner than the %s delay", i, latency, delay)
		}
	}
}

// checkDatagramsUnderConditions expects about the given loss, the delay and
// some reordering from the jitter.
func checkDatagramsUnderConditions(t *testing.T, sender, receiver Conn, conditions NetworkConditions) {
	t.Helper()
	const sent = 400
	loss, delay := conditions.Loss, conditions.Delay
	var mu sync.Mutex
	var order []int
	var early int
	var slowest time.Duration
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			payload, err := receiver.ReceiveUnreliable(ctx)
			if err != nil {
				return
			}
			index, n := binary.Uvarint(payload)
			stamp, _ := binary.Varint(payload[n:])
			latency := time.Since(time.Unix(0, stamp))
			mu.Lock()
			order = append(order, int(index))
			if latency < delay {
				early++
			}
			slowest = max(slowest, latency)
			done := len(order) >= sent
			mu.Unlock()
			if done {
				return
			}
		}
	}()
	for i := range sent {
		payload := binary.AppendVarint(binary.AppendUvarint(nil, uint64(i)), time.Now().UnixNano())
		if err := sender.SendUnreliable(payload); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Millisecond)
	}
	// Whatever is not here after the longest delay plus a margin was lost.
	time.AfterFunc(delay+conditions.Jitter+300*time.Millisecond, cancel)
	<-done
	mu.Lock()
	defer mu.Unlock()
	share := float64(len(order)) / sent
	inversions := 0
	for i := 1; i < len(order); i++ {
		if order[i] < order[i-1] {
			inversions++
		}
	}
	t.Logf("%d of %d datagrams arrived (%.1f%%), %d out of order, slowest after %s",
		len(order), sent, share*100, inversions, slowest.Round(time.Millisecond))
	if share < 1-2*loss || share > 1-loss/4 {
		t.Errorf("%d of %d datagrams arrived (%.1f%%) with %.0f%% loss", len(order), sent, share*100, loss*100)
	}
	if early > 0 {
		t.Errorf("%d datagrams arrived sooner than the %s delay", early, delay)
	}
	if inversions == 0 {
		t.Error("jitter did not reorder any datagram")
	}
}

func TestParseNetworkConditions(t *testing.T) {
	conditions, err := ParseNetworkConditions(" delay=80ms, jitter=15ms,loss=3%,dup=0.01,seed=9")
	want := NetworkConditions{Delay: 80 * time.Millisecond, Jitter: 15 * time.Millisecond, Loss: 0.03, Duplicate: 0.01, Seed: 9}
	if err != nil || conditions != want {
		t.Errorf("parsed %+v, %v", conditions, err)
	}
	if parsed, err := ParseNetworkConditions(want.String()); err != nil || parsed.Delay != want.Delay || parsed.Loss != want.Loss {
		t.Errorf("String() does not parse back: %q → %+v, %v", want.String(), parsed, err)
	}
	if none, err := ParseNetworkConditions(""); err != nil || none != (NetworkConditions{}) {
		t.Errorf("empty conditions: %+v, %v", none, err)
	}
	for _, text := range []string{"delay", "speed=1", "delay=fast", "loss=100%", "loss=-1%", "dup=2", "jitter=-5ms"} {
		if _, err := ParseNetworkConditions(text); err == nil {
			t.Errorf("%q accepted", text)
		}
	}
}

func TestMemoryListener(t *testing.T) {
	listener := NewMemoryListener()
	client, err := listener.Dial()
	if err != nil {
		t.Fatal(err)
	}
	server, err := listener.Accept(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := client.SendReliable(ChannelControl, []byte("hi")); err != nil {
		t.Fatal(err)
	}
	if _, payload := receiveReliable(t, server); string(payload) != "hi" {
		t.Errorf("got %q", payload)
	}
	_ = listener.Close()
	if _, err := listener.Accept(context.Background()); !errors.Is(err, ErrListenerClosed) {
		t.Errorf("accept after close: %v", err)
	}
	if _, err := listener.Dial(); !errors.Is(err, ErrListenerClosed) {
		t.Errorf("dial after close: %v", err)
	}
}

func TestQUICListenerServesSeveralClientsAndClosesThem(t *testing.T) {
	certificate, fingerprint := testCertificate(t)
	listener, err := ListenQUIC("127.0.0.1:0", ServerTLSConfig(certificate), QUICOptions{})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var clients []Conn
	for range 3 {
		client, err := DialQUIC(ctx, listener.Addr(), ClientTLSConfig(&fingerprint), QUICOptions{})
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close("test over")
		clients = append(clients, client)
		if _, err := listener.Accept(ctx); err != nil {
			t.Fatal(err)
		}
	}
	_ = listener.Close()
	if _, err := listener.Accept(ctx); !errors.Is(err, ErrListenerClosed) {
		t.Errorf("accept after close: %v", err)
	}
	for i, client := range clients {
		if _, _, err := client.ReceiveReliable(ctx); !errors.Is(err, ErrClosed) {
			t.Errorf("client %d after the listener closed: %v", i, err)
		}
	}
}

func TestClientPinsServerFingerprint(t *testing.T) {
	certificate, fingerprint := testCertificate(t)
	listener, err := ListenQUIC("127.0.0.1:0", ServerTLSConfig(certificate), QUICOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	wrong := fingerprint
	wrong[0] ^= 0xFF
	for name, c := range map[string]struct {
		expected *Fingerprint
		ok       bool
	}{"pinned": {&fingerprint, true}, "first contact": {nil, true}, "impostor": {&wrong, false}} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		client, err := DialQUIC(ctx, listener.Addr(), ClientTLSConfig(c.expected), QUICOptions{})
		cancel()
		if (err == nil) != c.ok {
			t.Errorf("%s: dial error %v", name, err)
		}
		if client != nil {
			_ = client.Close("done")
		}
	}
}

func newMemoryPair(t *testing.T) (Conn, Conn) {
	client, server := NewMemoryPair()
	t.Cleanup(func() { _ = client.Close("test over") })
	return client, server
}

func simulate(t *testing.T, conn Conn, conditions NetworkConditions) Conn {
	simulated := Simulate(conn, conditions)
	t.Cleanup(func() { _ = simulated.Close("test over") })
	return simulated
}

func packetSimulation(conditions NetworkConditions) QUICOptions {
	return QUICOptions{WrapPacketConn: func(conn net.PacketConn) net.PacketConn { return SimulatePackets(conn, conditions) }}
}

func newQUICPair(t *testing.T, clientOptions, serverOptions QUICOptions) (Conn, Conn) {
	t.Helper()
	certificate, fingerprint := testCertificate(t)
	listener, err := ListenQUIC("127.0.0.1:0", ServerTLSConfig(certificate), serverOptions)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := DialQUIC(ctx, listener.Addr(), ClientTLSConfig(&fingerprint), clientOptions)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close("test over") })
	server, err := listener.Accept(ctx)
	if err != nil {
		t.Fatal(err)
	}
	return client, server
}

var certificateOnce = sync.OnceValues(func() (certificateAndFingerprint, error) {
	certificate, fingerprint, err := GenerateCertificate()
	return certificateAndFingerprint{certificate, fingerprint}, err
})

type certificateAndFingerprint struct {
	certificate tls.Certificate
	fingerprint Fingerprint
}

func testCertificate(t *testing.T) (tls.Certificate, Fingerprint) {
	t.Helper()
	value, err := certificateOnce()
	if err != nil {
		t.Fatal(err)
	}
	return value.certificate, value.fingerprint
}

func receiveReliable(t *testing.T, conn Conn) (Channel, []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	channel, payload, err := conn.ReceiveReliable(ctx)
	if err != nil {
		t.Fatal(err)
	}
	return channel, payload
}

func receiveUnreliable(t *testing.T, conn Conn) []byte {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	payload, err := conn.ReceiveUnreliable(ctx)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}
