package client

import (
	"fmt"
	"time"

	"ravenfield/internal/network/protocol"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	// The graph keeps graphBuckets buckets of graphBucket seconds each.
	graphBuckets = 60
	graphBucket  = 0.1
	// graphRecent is how many of the newest buckets the text averages over.
	graphRecent = 10
)

// netBucket is what happened on the network during one bucket of time.
type netBucket struct {
	bytes, datagrams int
	// expected counts the snapshot sequences that went by, for the loss.
	expected int
	// lead is the smallest input lead the server reported, if any; late
	// counts snapshots that reported commands arriving late.
	lead          int8
	hasLead       bool
	late          int
	corrections   int
	correction    float32
	aimedUpdates  int
	rtt           time.Duration
	dilation      float64
	hasCorrection bool
}

// netGraph is the client's network overlay (ARCHITECTURE.md, 6.13), toggled
// with F2: the last few seconds by bucket, and averages of the last second.
type netGraph struct {
	buckets  [graphBuckets]netBucket
	current  int
	elapsed  float32
	sequence uint16
	started  bool
	// The soldier under the crosshair and how many updates it had, to count
	// its update rate.
	aimed        uint16
	aimedUpdates int
}

func (g *netGraph) bucket() *netBucket {
	return &g.buckets[g.current]
}

// datagram records a snapshot datagram of the given size.
func (g *netGraph) datagram(size int, snapshot *protocol.Snapshot) {
	b := g.bucket()
	b.bytes += size
	b.datagrams++
	if !g.started {
		g.sequence, g.started = snapshot.Sequence, true
		b.expected++
	} else if gap := int16(snapshot.Sequence - g.sequence); gap > 0 {
		g.sequence = snapshot.Sequence
		b.expected += int(gap)
	}
	if lead := snapshot.Player.InputLead; snapshot.Player.Processed && lead != protocol.NoInput {
		if !b.hasLead || lead < b.lead {
			b.lead, b.hasLead = lead, true
		}
		if lead < 0 {
			b.late++
		}
	}
}

// correction records a correction of the prediction of the given size.
func (g *netGraph) correction(size float32) {
	b := g.bucket()
	b.corrections++
	b.correction = max(b.correction, size)
	b.hasCorrection = true
}

// frame advances the graph by a frame. aimed is the soldier nearest to the
// crosshair, zero for none, and updates how many states the client has had of
// it so far.
func (g *netGraph) frame(deltaTime float32, rtt time.Duration, dilation float64, aimed uint16, updates int) {
	b := g.bucket()
	if aimed != 0 && aimed == g.aimed {
		b.aimedUpdates += updates - g.aimedUpdates
	}
	g.aimed, g.aimedUpdates = aimed, updates
	b.rtt, b.dilation = rtt, dilation
	if g.elapsed += deltaTime; g.elapsed >= graphBucket {
		g.elapsed -= graphBucket
		g.current = (g.current + 1) % graphBuckets
		g.buckets[g.current] = netBucket{}
	}
}

// recent sums the last second, without the bucket still filling.
func (g *netGraph) recent() (sum netBucket) {
	for i := 1; i <= graphRecent; i++ {
		b := &g.buckets[(g.current-i+graphBuckets)%graphBuckets]
		sum.bytes += b.bytes
		sum.datagrams += b.datagrams
		sum.expected += b.expected
		sum.late += b.late
		sum.corrections += b.corrections
		sum.correction = max(sum.correction, b.correction)
		sum.aimedUpdates += b.aimedUpdates
		if b.hasLead && (!sum.hasLead || b.lead < sum.lead) {
			sum.lead, sum.hasLead = b.lead, true
		}
	}
	last := g.buckets[(g.current-1+graphBuckets)%graphBuckets]
	sum.rtt, sum.dilation = last.rtt, last.dilation
	return sum
}

// draw shows the graph in the bottom left corner: the smallest input lead of
// every bucket against the target, and the snapshot traffic.
func (g *netGraph) draw(jumps int) {
	const (
		width, height = 360, 70
		barWidth      = width / graphBuckets
		leadScale     = 6 // pixels per tick of lead
	)
	left, top := int32(18), int32(rl.GetScreenHeight())-int32(2*height+150)
	sum := g.recent()
	loss := 0.0
	if sum.expected > 0 {
		loss = 100 * max(0, 1-float64(sum.datagrams)/float64(sum.expected))
	}
	lines := []string{
		fmt.Sprintf("RTT %d ms | snapshot loss %.1f%%", sum.rtt.Milliseconds(), loss),
		fmt.Sprintf("snapshots %.1f KB/s, %d datagrams/s", float64(sum.bytes)/1024, sum.datagrams),
		fmt.Sprintf("input lead %d (target %d) | clock %+.1f%% | jumps %d | late %d/s", sum.lead, commandLead, 100*sum.dilation, jumps, sum.late),
		fmt.Sprintf("corrections %d/s (largest %.3f m) | aimed soldier %d Hz", sum.corrections, sum.correction, sum.aimedUpdates),
	}
	rl.DrawRectangle(left-6, top-6, width+12, 2*height+16+int32(len(lines))*20, rl.NewColor(0, 0, 0, 140))
	// Input lead: the target as a line, every bucket's smallest lead as a bar
	// from zero, red when commands came late.
	zero := top + height - 10
	rl.DrawLine(left, zero-commandLead*leadScale, left+width, zero-commandLead*leadScale, rl.DarkGreen)
	rl.DrawLine(left, zero, left+width, zero, rl.Gray)
	for i := range graphBuckets {
		b := &g.buckets[(g.current+1+i)%graphBuckets]
		if !b.hasLead {
			continue
		}
		x := left + int32(i*barWidth)
		lead := int32(max(-1, min(9, int(b.lead)))) * leadScale
		color := rl.SkyBlue
		if b.lead < 0 {
			color, lead = rl.Red, -leadScale
		}
		if lead >= 0 {
			rl.DrawRectangle(x, zero-lead, barWidth-1, lead+1, color)
		} else {
			rl.DrawRectangle(x, zero, barWidth-1, -lead, color)
		}
		if b.hasCorrection {
			rl.DrawRectangle(x, top, barWidth-1, 4, rl.Orange)
		}
	}
	// Snapshot traffic per bucket, scaled to 64 KB/s at the top.
	base := top + 2*height + 4
	for i := range graphBuckets {
		b := &g.buckets[(g.current+1+i)%graphBuckets]
		bar := int32(float64(b.bytes) / graphBucket / (64 * 1024) * height)
		rl.DrawRectangle(left+int32(i*barWidth), base-min(bar, height), barWidth-1, min(bar, height), rl.Gold)
	}
	rl.DrawText("input lead", left+width-80, top, 14, rl.LightGray)
	rl.DrawText("snapshot bytes", left+width-110, top+height+8, 14, rl.LightGray)
	for i, line := range lines {
		rl.DrawText(line, left, base+8+int32(i)*20, 16, rl.White)
	}
}
