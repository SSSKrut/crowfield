// Command loadtest plays headless clients against a server through the real
// network stack: QUIC, the protocol and the whole client path. Without
// -connect it starts its own server with dummies on the loopback.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"syscall"
	"time"

	"ravenfield/internal/client"
	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
	"ravenfield/internal/simulation"
)

func main() {
	clients := flag.Int("clients", 16, "headless clients")
	duration := flag.Duration("duration", time.Minute, "how long the clients play")
	report := flag.Duration("report", 10*time.Second, "interval between reports")
	connect := flag.String("connect", "", "server address; empty starts a server here")
	fingerprint := flag.String("fingerprint", "", "certificate fingerprint the -connect server must have")
	dummies := flag.Int("dummies", 256, "dummies of the server started here")
	netsim := flag.String("netsim", "", "simulate network conditions for every client, e.g. delay=50ms,jitter=10ms,loss=2%")
	flag.Parse()
	if err := run(*clients, *duration, *report, *connect, *fingerprint, *dummies, *netsim); err != nil {
		log.Fatal(err)
	}
}

func run(count int, duration, report time.Duration, address, fingerprint string, dummies int, netsim string) error {
	conditions, err := transport.ParseNetworkConditions(netsim)
	if err != nil {
		return err
	}
	var pinned *transport.Fingerprint
	if fingerprint != "" {
		parsed, err := transport.ParseFingerprint(fingerprint)
		if err != nil {
			return err
		}
		pinned = &parsed
	}
	if err := physics.Init(); err != nil {
		return err
	}
	defer physics.Shutdown()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if address == "" {
		server, err := startServer(ctx, dummies, report)
		if err != nil {
			return err
		}
		defer server.stop()
		address = server.address
	}
	rules := game.DefaultRules()
	players := make([]*client.Headless, 0, count)
	defer func() {
		for _, p := range players {
			p.Close()
		}
	}()
	// Every client plays as soon as it joins: a joined client that sends no
	// commands would only measure the wait.
	playCtx, cancel := context.WithTimeout(ctx, duration)
	defer cancel()
	var failures sync.Map
	var group sync.WaitGroup
	for i := range count {
		dialCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		conn, err := transport.DialQUIC(dialCtx, address, transport.ClientTLSConfig(pinned), transport.QUICOptions{})
		cancel()
		if err != nil {
			return fmt.Errorf("client %d: %w", i, err)
		}
		if conditions != (transport.NetworkConditions{}) {
			conditions.Seed = uint64(i + 1)
			conn = transport.Simulate(conn, conditions)
		}
		player, err := client.NewHeadless(conn, fmt.Sprintf("load-%02d", i), rules, uint64(i+1))
		if err != nil {
			_ = conn.Close("join failed")
			return fmt.Errorf("client %d: %w", i, err)
		}
		players = append(players, player)
		group.Go(func() {
			if err := player.Run(playCtx); err != nil {
				failures.Store(i, err)
				log.Printf("client %d: %v", i, err)
			}
		})
	}
	log.Printf("loadtest: %d clients joined %s for %s", count, address, duration)
	start := time.Now()
	ticker := time.NewTicker(report)
	defer ticker.Stop()
	var previous []client.HeadlessStats
	var settledHeap uint64
	for done := false; !done; {
		select {
		case <-playCtx.Done():
			done = true
		case <-ticker.C:
		}
		interval := summarize(players, previous)
		heap := heapInUse()
		if settledHeap == 0 && time.Since(start) >= time.Minute {
			settledHeap = heap
		}
		log.Printf("loadtest %4.0fs: %s heap=%.1fMB goroutines=%d",
			time.Since(start).Seconds(), interval, float64(heap)/(1<<20), runtime.NumGoroutine())
		previous = stats(players)
	}
	group.Wait()
	total := summarize(players, nil)
	log.Printf("loadtest finished after %s: %s", time.Since(start).Round(time.Second), total)
	if settledHeap > 0 {
		heap := heapInUse()
		log.Printf("heap after the first minute %.1f MB, at the end %.1f MB (%+.1f%%)",
			float64(settledHeap)/(1<<20), float64(heap)/(1<<20), 100*(float64(heap)/float64(settledHeap)-1))
	}
	failed := 0
	failures.Range(func(any, any) bool { failed++; return true })
	if failed > 0 || total.unresolved > 0 {
		return fmt.Errorf("%d clients failed, %d snapshot datagrams did not resolve", failed, total.unresolved)
	}
	return nil
}

type summary struct {
	clients, ticks, snapshots, jumps, corrections, unresolved, late int
	shots, weaponCorrections                                        int
	bytes                                                           int64
	seconds                                                         float64
	lowestLead                                                      float64
	largestCorrection                                               float32
}

func (s summary) String() string {
	perClient := float64(s.bytes) / 1024 / max(s.seconds, 1e-3) / float64(max(1, s.clients))
	return fmt.Sprintf("clients=%d ticks/s=%.1f snapshots/s=%.1f snapshots=%.1fKB/s/client jumps=%d corrections=%d (largest %.3fm, weapons only %d) shots=%d late=%d unresolved=%d lowest_lead=%.2f",
		s.clients, float64(s.ticks)/max(s.seconds, 1e-3)/float64(max(1, s.clients)),
		float64(s.snapshots)/max(s.seconds, 1e-3)/float64(max(1, s.clients)), perClient,
		s.jumps, s.corrections, s.largestCorrection, s.weaponCorrections, s.shots, s.late, s.unresolved, s.lowestLead)
}

// summarize adds up the clients since the previous stats, or from the start
// without them. Rates assume 60 ticks a second of play.
func summarize(players []*client.Headless, previous []client.HeadlessStats) summary {
	sum := summary{clients: len(players), lowestLead: 99}
	for i, current := range stats(players) {
		var before client.HeadlessStats
		if previous != nil {
			before = previous[i]
		}
		sum.ticks += current.Ticks - before.Ticks
		sum.snapshots += current.Snapshots - before.Snapshots
		sum.bytes += current.Bytes - before.Bytes
		sum.jumps += current.Jumps - before.Jumps
		sum.corrections += current.Corrections - before.Corrections
		sum.unresolved += current.Unresolved - before.Unresolved
		sum.late += current.Late - before.Late
		sum.shots += current.Shots - before.Shots
		sum.weaponCorrections += current.WeaponCorrections - before.WeaponCorrections
		sum.lowestLead = min(sum.lowestLead, current.Lead)
		sum.largestCorrection = max(sum.largestCorrection, current.LargestCorrection)
	}
	sum.seconds = float64(sum.ticks) / game.TickRate / float64(max(1, len(players)))
	return sum
}

func stats(players []*client.Headless) []client.HeadlessStats {
	all := make([]client.HeadlessStats, len(players))
	for i, p := range players {
		all[i] = p.Stats()
	}
	return all
}

// heapInUse collects garbage first, so that it measures what is kept.
func heapInUse() uint64 {
	runtime.GC()
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	return memory.HeapInuse
}

type server struct {
	address string
	stop    func()
}

func startServer(ctx context.Context, dummies int, report time.Duration) (*server, error) {
	settings := config.DefaultServer()
	settings.Dummies = dummies
	settings.StatsInterval = report
	certificate, _, err := transport.GenerateCertificate()
	if err != nil {
		return nil, err
	}
	listener, err := transport.ListenQUIC("127.0.0.1:0", transport.ServerTLSConfig(certificate), transport.QUICOptions{})
	if err != nil {
		return nil, err
	}
	simulated, err := simulation.NewServer(settings, game.DefaultRules())
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	serveCtx, cancel := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() { done <- simulated.Serve(serveCtx, listener) }()
	log.Printf("loadtest: server with %d dummies on %s", dummies, listener.Addr())
	return &server{address: listener.Addr(), stop: func() {
		cancel()
		if err := <-done; err != nil && !errors.Is(err, context.Canceled) {
			fmt.Fprintln(os.Stderr, "server:", err)
		}
		_ = listener.Close()
		_ = simulated.Close()
	}}, nil
}
