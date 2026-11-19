package simulation

import (
	"fmt"
	"strings"
	"time"
)

type system int

const (
	systemEvents system = iota
	systemPlayers
	systemDummies
	systemShots
	systemPhysics
	systemGrid
	systemHistory
	systemSnapshots
	systemCount
)

var systemNames = [systemCount]string{"events", "players", "dummies", "shots", "physics", "grid", "history", "snapshots"}

// tickProfile measures where tick time goes, per system, between two log lines.
type tickProfile struct {
	ticks          int
	total, longest time.Duration
	systems        [systemCount]time.Duration
	missedCommands uint64
	// shots counts the shots fired, hits those that struck a soldier, and
	// kills the soldiers that died.
	shots, hits, kills uint64
	// snapshotBytes counts what snapshots cost on the wire, with the estimated
	// overhead of every datagram.
	snapshotBytes uint64
	mark          time.Time
}

func (p *tickProfile) start() {
	p.mark = time.Now()
}

// lap charges the time since the previous lap to a system.
func (p *tickProfile) lap(s system) {
	now := time.Now()
	p.systems[s] += now.Sub(p.mark)
	p.mark = now
}

func (p *tickProfile) finish(started time.Time) {
	elapsed := time.Since(started)
	p.ticks++
	p.total += elapsed
	p.longest = max(p.longest, elapsed)
}

// String reports average and longest tick and the average share of each system.
func (p *tickProfile) String() string {
	if p.ticks == 0 {
		return "no ticks"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "tick avg=%s max=%s |", p.average(p.total), p.longest.Round(time.Microsecond))
	for s, name := range systemNames {
		fmt.Fprintf(&b, " %s=%s", name, p.average(p.systems[s]))
	}
	return b.String()
}

func (p *tickProfile) average(total time.Duration) time.Duration {
	return (total / time.Duration(p.ticks)).Round(time.Microsecond)
}
