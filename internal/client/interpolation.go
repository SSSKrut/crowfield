package client

import (
	"math"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

const (
	remoteSamples = 16
	// Past the newest state a soldier keeps moving by its velocity for at most
	// this long, then stands until a snapshot comes. Far soldiers out of sight
	// are updated once or twice a second and live on this.
	maxExtrapolation = game.TickRate / 2
	// A soldier drawn off its new path catches up with this time constant,
	// about 95 % within 0.3 s; a jump longer than catchUpDistance is shown at
	// once, like a respawn.
	catchUpTime     = 0.1
	catchUpDistance = 3
	// interpolationSnapshots is the delay in snapshot intervals: with one
	// snapshot lost there is still a later one to interpolate towards.
	interpolationSnapshots = 2
)

type remoteSample struct {
	tick    game.Tick
	soldier game.Soldier
}

// remoteSoldier keeps the latest states of another soldier, so that it can be
// drawn smoothly in the recent past, between two states the client has.
type remoteSoldier struct {
	samples [remoteSamples]remoteSample
	count   int
	// offset is what is left of a correction: where the soldier was drawn
	// minus where its states put it now.
	offset physics.Vec3
}

// add keeps the samples ordered by tick. A late datagram older than the newest
// sample is dropped; parts of one snapshot replace each other. A grounded
// soldier's downward velocity only keeps it on the floor, so it is not used
// for drawing: it would sink the soldier between snapshots.
func (r *remoteSoldier) add(tick game.Tick, soldier game.Soldier) {
	if soldier.Grounded {
		soldier.Velocity.Y = 0
	}
	if r.count > 0 {
		newest := &r.samples[(r.count-1)%remoteSamples]
		if tick == newest.tick {
			newest.soldier = soldier
			return
		}
		if tick < newest.tick {
			return
		}
	}
	r.samples[r.count%remoteSamples] = remoteSample{tick: tick, soldier: soldier}
	r.count++
}

// keep turns the change a new state made to the drawn position at renderTick
// into an offset that fades, so the soldier does not jump.
func (r *remoteSoldier) keep(drawn physics.Vec3, renderTick float64) {
	r.offset = r.offset.Add(drawn.Sub(r.at(renderTick).Position))
	if distance(r.offset, physics.Vec3{}) > catchUpDistance {
		r.offset = physics.Vec3{}
	}
}

func (r *remoteSoldier) smooth(deltaTime float32) {
	r.offset = r.offset.Mul(float32(math.Exp(-float64(deltaTime) / catchUpTime)))
}

// at returns the soldier drawn at a fractional tick, with what is left of a
// correction.
func (r *remoteSoldier) at(renderTick float64) game.Soldier {
	soldier := r.interpolate(renderTick)
	soldier.Position = soldier.Position.Add(r.offset)
	return soldier
}

// interpolate returns the soldier at a fractional tick: by cubic Hermite
// interpolation of position and velocity between the two states around it, and
// past the newest state by its velocity for a while.
// lastAlive is the newest state in which the soldier was alive, for the
// momentum it falls with: a dead one stands still.
func (r *remoteSoldier) lastAlive() game.Soldier {
	for i := r.count - 1; i >= max(0, r.count-remoteSamples); i-- {
		if sample := r.samples[i%remoteSamples]; sample.soldier.Alive {
			return sample.soldier
		}
	}
	return r.samples[(r.count-1)%remoteSamples].soldier
}

func (r *remoteSoldier) interpolate(renderTick float64) game.Soldier {
	oldest := max(0, r.count-remoteSamples)
	newest := r.samples[(r.count-1)%remoteSamples]
	if renderTick >= float64(newest.tick) {
		soldier := newest.soldier
		elapsed := float32(min(renderTick-float64(newest.tick), maxExtrapolation) / game.TickRate)
		soldier.Position = soldier.Position.Add(soldier.Velocity.Mul(elapsed))
		return soldier
	}
	for i := r.count - 1; i > oldest; i-- {
		earlier := r.samples[(i-1)%remoteSamples]
		if renderTick >= float64(earlier.tick) {
			return hermite(earlier, r.samples[i%remoteSamples], renderTick)
		}
	}
	return r.samples[oldest%remoteSamples].soldier
}

func hermite(earlier, later remoteSample, renderTick float64) game.Soldier {
	start, end := float64(earlier.tick), float64(later.tick)
	span := float32((end - start) / game.TickRate)
	u := float32((renderTick - start) / (end - start))
	u2, u3 := u*u, u*u*u
	soldier := earlier.soldier
	if u >= 0.5 {
		soldier = later.soldier
	}
	// A soldier dies at the tick of its first dead state, where the server
	// left it, not halfway there: far soldiers come a second apart.
	soldier.Alive = earlier.soldier.Alive
	soldier.Position = earlier.soldier.Position.Mul(2*u3 - 3*u2 + 1).
		Add(earlier.soldier.Velocity.Mul((u3 - 2*u2 + u) * span)).
		Add(later.soldier.Position.Mul(-2*u3 + 3*u2)).
		Add(later.soldier.Velocity.Mul((u3 - u2) * span))
	soldier.Velocity = earlier.soldier.Velocity.Add(later.soldier.Velocity.Sub(earlier.soldier.Velocity).Mul(u))
	soldier.Yaw = lerpAngle(earlier.soldier.Yaw, later.soldier.Yaw, u)
	soldier.Pitch = earlier.soldier.Pitch + (later.soldier.Pitch-earlier.soldier.Pitch)*u
	return soldier
}

func lerpAngle(from, to, u float32) float32 {
	delta := math.Remainder(float64(to-from), 2*math.Pi)
	return from + float32(delta)*u
}

// interpolationClock is the client's view of server time minus the
// interpolation delay. It runs with the frame clock and is pulled gently
// towards each snapshot, so jitter does not shake the remote soldiers.
type interpolationClock struct {
	renderTick float64
	delay      float64
	started    bool
}

func newInterpolationClock(snapshotRate int) interpolationClock {
	interval := float64(game.TickRate) / float64(max(1, snapshotRate))
	return interpolationClock{delay: interpolationSnapshots*interval + 1}
}

func (c *interpolationClock) observe(serverTick game.Tick) {
	target := float64(serverTick) - c.delay
	if !c.started || math.Abs(target-c.renderTick) > 30 {
		c.renderTick, c.started = target, true
		return
	}
	c.renderTick += (target - c.renderTick) * 0.1
}

func (c *interpolationClock) advance(deltaTime float32) {
	c.renderTick += float64(deltaTime) * game.TickRate
}
