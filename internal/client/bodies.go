package client

import (
	"image/color"

	"ravenfield/internal/animation"
	"ravenfield/internal/physics"
	"ravenfield/internal/render"
)

const (
	// At most maxRagdolls bodies are simulated at once: for a new one the
	// farthest of them freezes early (ARCHITECTURE.md, 10.2).
	maxRagdolls = 64
	// At most maxBodies fallen bodies stay, each for bodyLifetime seconds;
	// beyond that the oldest goes first.
	maxBodies    = 128
	bodyLifetime = 30
)

type body struct {
	character *animation.Character
	tint      color.RGBA
	age       float32
}

// bodies are fallen soldiers that no longer belong to anyone: they fall as
// ragdolls, freeze, and fade after a while.
type bodies struct {
	all []body
	// peak is the most ragdolls simulated at once so far.
	peak int
}

// add takes a character that has just become a ragdoll. The eye decides which
// ragdoll is the farthest, should there be too many.
func (b *bodies) add(character *animation.Character, tint color.RGBA, eye physics.Vec3) error {
	if b.ragdolls() >= maxRagdolls {
		farthest, longest := -1, float32(-1)
		for i := range b.all {
			if d := distance(b.all[i].character.FallenAt(), eye); b.all[i].character.RagdollActive() && d > longest {
				farthest, longest = i, d
			}
		}
		if err := b.all[farthest].character.Freeze(); err != nil {
			return err
		}
	}
	if len(b.all) >= maxBodies {
		if err := b.remove(0); err != nil {
			return err
		}
	}
	b.all = append(b.all, body{character: character, tint: tint})
	b.peak = max(b.peak, b.ragdolls())
	return nil
}

func (b *bodies) ragdolls() int {
	count := 0
	for i := range b.all {
		if b.all[i].character.RagdollActive() {
			count++
		}
	}
	return count
}

func (b *bodies) update(deltaTime float32) error {
	for i := 0; i < len(b.all); i++ {
		b.all[i].age += deltaTime
		if b.all[i].age >= bodyLifetime {
			if err := b.remove(i); err != nil {
				return err
			}
			i--
			continue
		}
		if err := b.all[i].character.Update(deltaTime, 0); err != nil {
			return err
		}
	}
	return nil
}

func (b *bodies) draw(frustum *render.Frustum) int {
	drawn := 0
	for i := range b.all {
		if frustum.Sees(b.all[i].character.FallenAt(), soldierRadius) {
			b.all[i].character.Draw(physics.Vec3{}, physics.Quat{}, b.all[i].tint, animation.DetailCached)
			drawn++
		}
	}
	return drawn
}

func (b *bodies) remove(i int) error {
	err := b.all[i].character.Close()
	b.all = append(b.all[:i], b.all[i+1:]...)
	return err
}

func (b *bodies) close() {
	for i := range b.all {
		_ = b.all[i].character.Close()
	}
	b.all = nil
}
