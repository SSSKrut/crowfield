package client

import (
	"image/color"
	"math/rand/v2"

	"ravenfield/internal/physics"
	"ravenfield/internal/render"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	// Pools of effects with limits (ARCHITECTURE.md, 10.3): past a limit the
	// oldest gives way.
	maxTracers = 64
	maxImpacts = 128
	maxSparks  = 256
	// A tracer is a streak tracerLength long flying at tracerSpeed.
	tracerSpeed  = 400
	tracerLength = 3
	// A bullet hole stays impactLifetime seconds and fades in the last one.
	impactLifetime = 20
	impactSize     = 0.045
	sparksPerHit   = 6
	sparkLifetime  = 0.45
	sparkGravity   = 9.81
)

var (
	tracerColor = rl.NewColor(255, 214, 140, 210)
	impactColor = rl.NewColor(28, 26, 24, 255)
	sparkColors = [...]color.RGBA{rl.NewColor(170, 160, 140, 255), rl.NewColor(130, 120, 105, 255), rl.NewColor(255, 200, 110, 255)}
)

type tracer struct {
	from, direction physics.Vec3
	length, flown   float32
}

type impact struct {
	position physics.Vec3
	age      float32
}

type spark struct {
	position, velocity physics.Vec3
	age                float32
	tint               color.RGBA
}

// effects are what shots leave in the world: tracers, bullet holes and the
// dust they kick up. They are cosmetic; where a shot hits is the server's
// call, and the client only shows its own guess of the wall it struck.
type effects struct {
	tracers []tracer
	impacts []impact
	sparks  []spark
	random  *rand.Rand
}

func newEffects() *effects {
	return &effects{
		tracers: make([]tracer, 0, maxTracers), impacts: make([]impact, 0, maxImpacts), sparks: make([]spark, 0, maxSparks),
		random: rand.New(rand.NewPCG(1, 2)),
	}
}

// shot adds the tracer of a shot from the muzzle to where it ends, and a hole
// with dust when it struck something there.
func (e *effects) shot(muzzle, end physics.Vec3, struck bool) {
	path := end.Sub(muzzle)
	length := distance(end, muzzle)
	if length > 0.5 {
		e.tracers = appendLimited(e.tracers, tracer{from: muzzle, direction: path.Mul(1 / length), length: length})
	}
	if !struck {
		return
	}
	e.impacts = appendLimited(e.impacts, impact{position: end})
	back := path.Mul(-1 / max(length, 1e-3))
	for range sparksPerHit {
		scatter := physics.V(e.random.Float32()*2-1, e.random.Float32()*2-1, e.random.Float32()*2-1)
		velocity := back.Mul(1.5 + 2*e.random.Float32()).Add(scatter.Mul(1.2)).Add(physics.V(0, 1, 0))
		e.sparks = appendLimited(e.sparks, spark{
			position: end, velocity: velocity, tint: sparkColors[e.random.IntN(len(sparkColors))],
		})
	}
}

// appendLimited adds to a pool, dropping its oldest at the limit.
func appendLimited[T any](pool []T, item T) []T {
	if len(pool) == cap(pool) {
		copy(pool, pool[1:])
		pool = pool[:len(pool)-1]
	}
	return append(pool, item)
}

func (e *effects) update(deltaTime float32) {
	kept := e.tracers[:0]
	for _, t := range e.tracers {
		if t.flown += tracerSpeed * deltaTime; t.flown-tracerLength < t.length {
			kept = append(kept, t)
		}
	}
	e.tracers = kept
	holes := e.impacts[:0]
	for _, i := range e.impacts {
		if i.age += deltaTime; i.age < impactLifetime {
			holes = append(holes, i)
		}
	}
	e.impacts = holes
	sparks := e.sparks[:0]
	for _, s := range e.sparks {
		s.age += deltaTime
		s.velocity.Y -= sparkGravity * deltaTime
		s.position = s.position.Add(s.velocity.Mul(deltaTime))
		if s.age < sparkLifetime {
			sparks = append(sparks, s)
		}
	}
	e.sparks = sparks
}

func (e *effects) draw() {
	for _, i := range e.impacts {
		tint := impactColor
		tint.A = uint8(255 * min(1, impactLifetime-i.age))
		rl.DrawCube(render.Vector(i.position), impactSize, impactSize, impactSize, tint)
	}
	for _, s := range e.sparks {
		size := 0.025 * (1 - s.age/sparkLifetime)
		rl.DrawCube(render.Vector(s.position), size, size, size, s.tint)
	}
	rl.BeginBlendMode(rl.BlendAdditive)
	for _, t := range e.tracers {
		head := min(t.flown, t.length)
		tail := max(0, t.flown-tracerLength)
		if head <= tail {
			continue
		}
		start := render.Vector(t.from.Add(t.direction.Mul(tail)))
		end := render.Vector(t.from.Add(t.direction.Mul(head)))
		rl.DrawCylinderEx(start, end, 0.004, 0.012, 4, tracerColor)
	}
	rl.EndBlendMode()
}
