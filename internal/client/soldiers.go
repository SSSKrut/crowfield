package client

import (
	"cmp"
	"image/color"
	"math"
	"slices"

	"ravenfield/internal/animation"
	"ravenfield/internal/game"
	"ravenfield/internal/physics"
	"ravenfield/internal/render"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	// The fullDetail soldiers nearest to the camera within fullDetailDistance
	// get an exact pose with blended clips; the rest show precomputed
	// keyframes. Beyond capsuleDistance a soldier is a capsule.
	fullDetail         = 8
	fullDetailDistance = 20
	capsuleDistance    = 150
	// soldierRadius bounds a soldier for culling, around the middle of its body.
	soldierRadius = 1.2
	// knockDown is how many of the nearest soldiers the debug key knocks down.
	knockDown = 16
)

var teamNames = [...]string{game.TeamNone: "no", game.TeamBlue: "blue", game.TeamRed: "red"}

var teamColors = map[game.Team]color.RGBA{
	game.TeamBlue: rl.NewColor(60, 110, 220, 255), game.TeamRed: rl.NewColor(210, 70, 60, 255),
}

// remoteView is another soldier as it is drawn this frame.
type remoteView struct {
	soldier   game.Soldier
	known     *knownSoldier
	character *animation.Character
	distance  float32
	detail    animation.Detail
	capsule   bool
}

// soldiers draws every other soldier with the shared character asset. Each
// has its own animation state, made when the soldier is first seen and
// dropped when it is gone. A soldier that dies falls as a ragdoll into the
// bodies of the world.
type soldiers struct {
	asset      *animation.CharacterAsset
	world      *physics.World
	bodies     *bodies
	characters map[game.SoldierID]*animation.Character
	views      []remoteView
	frustum    render.Frustum
	// What the last frame drew, for the overlay and the log.
	drawn, full, capsules int
	// aimed is the soldier nearest to the crosshair, if any.
	aimed *knownSoldier
}

func newSoldiers(asset *animation.CharacterAsset) *soldiers {
	return &soldiers{asset: asset, characters: make(map[game.SoldierID]*animation.Character)}
}

// update places every other soldier at the interpolation time, advances its
// animation and chooses how to draw it from the camera. A soldier that is
// dead at that time falls.
func (s *soldiers) update(session *session, deltaTime float32, camera rl.Camera3D, aspect float32) error {
	s.frustum = render.NewFrustum(camera, aspect)
	eye := physics.V(camera.Position.X, camera.Position.Y, camera.Position.Z)
	s.views = s.views[:0]
	for id := range s.characters {
		if known := session.soldiers[id.Slot()]; known == nil || known.soldier.ID != id {
			delete(s.characters, id)
		}
	}
	for _, known := range session.soldiers {
		id := known.soldier.ID
		if id == session.player.Soldier || known.remote.count == 0 {
			continue
		}
		known.remote.smooth(deltaTime)
		soldier := known.remote.at(session.clock.renderTick)
		character := s.characters[id]
		if !soldier.Alive {
			if character != nil {
				delete(s.characters, id)
				if err := s.fall(character, soldier, eye); err != nil {
					return err
				}
			}
			continue
		}
		if character == nil {
			character = s.asset.NewCharacter()
			s.characters[id] = character
		}
		_ = character.Update(deltaTime, horizontalSpeed(soldier.Velocity))
		if !s.frustum.Sees(soldier.Position.Add(physics.V(0, soldierRadius, 0)), soldierRadius) {
			continue
		}
		view := remoteView{
			soldier: soldier, known: known, character: character, distance: distance(soldier.Position, eye), detail: animation.DetailCached,
		}
		view.capsule = view.distance > capsuleDistance
		s.views = append(s.views, view)
	}
	slices.SortFunc(s.views, func(first, second remoteView) int { return cmp.Compare(first.distance, second.distance) })
	for i := range min(fullDetail, len(s.views)) {
		if s.views[i].distance <= fullDetailDistance {
			s.views[i].detail = animation.DetailFull
		}
	}
	return nil
}

// fall turns a soldier that died into a ragdoll from its pose, knocked back.
// Far away, where it would be a capsule, it is simply gone.
func (s *soldiers) fall(character *animation.Character, soldier game.Soldier, eye physics.Vec3) error {
	if s.world == nil || distance(soldier.Position, eye) > capsuleDistance {
		return character.Close()
	}
	impulse := game.ViewDirection(soldier.Yaw, 0).Mul(-25).Add(physics.V(0, 10, 0))
	if err := character.CreateRagdoll(s.world, soldier.Position, facing(soldier.Yaw), soldier.Velocity, impulse); err != nil {
		_ = character.Close()
		return err
	}
	return s.bodies.add(character, s.tint(soldier.Team), eye)
}

// aim finds the soldier nearest to the line of sight, within a few degrees,
// as the server does for its priorities: from the soldier's eye along the
// command's direction, whatever the camera, to the middle of the body.
func (s *soldiers) aim(eye, forward physics.Vec3, center float32) {
	const limit = 3 * math.Pi / 180
	var aimed *knownSoldier
	best := float64(limit)
	for _, view := range s.views {
		to := view.soldier.Position.Add(physics.V(0, center, 0)).Sub(eye)
		length := distance(to, physics.Vec3{})
		angle := math.Acos(float64(max(-1, min(1, forward.Dot(to)/length)))) - math.Atan(0.5/float64(length))
		if angle < best {
			aimed, best = view.known, angle
		}
	}
	s.aimed = aimed
}

func (s *soldiers) draw(tuning game.MovementTuning, debug bool) {
	s.drawn, s.full, s.capsules = len(s.views), 0, 0
	for _, view := range s.views {
		tint := s.tint(view.soldier.Team)
		switch {
		case view.capsule:
			drawCapsule(tuning, view.soldier, tint)
			s.capsules++
		default:
			view.character.Draw(view.soldier.Position, facing(view.soldier.Yaw), tint, view.detail)
			if view.detail == animation.DetailFull {
				s.full++
			}
		}
		if debug {
			drawHitboxes(view.soldier)
		}
	}
}

func (s *soldiers) tint(team game.Team) color.RGBA {
	if tint, ok := teamColors[team]; ok {
		return tint
	}
	return s.asset.Accent()
}

// knockDown drops ragdoll copies of the nearest soldiers in view, pushed away
// from the eye. The soldiers walk on: the server knows nothing of it. It
// tries the ragdoll limits until soldiers can die (stage 2).
func (s *soldiers) knockDown(world *physics.World, fallen *bodies, eye physics.Vec3) error {
	for _, view := range s.views[:min(knockDown, len(s.views))] {
		away := view.soldier.Position.Sub(eye)
		away.Y = 0
		length := float32(math.Hypot(float64(away.X), float64(away.Z)))
		impulse := away.Mul(35 / max(length, 1e-3)).Add(physics.V(0, 20, 0))
		character := view.character.Copy()
		if err := character.CreateRagdoll(world, view.soldier.Position, facing(view.soldier.Yaw), view.soldier.Velocity, impulse); err != nil {
			_ = character.Close()
			return err
		}
		if err := fallen.add(character, s.tint(view.soldier.Team), eye); err != nil {
			return err
		}
	}
	return nil
}

var zoneColors = [...]color.RGBA{game.ZoneHead: rl.Red, game.ZoneTorso: rl.Yellow, game.ZoneLimb: rl.Green}

// drawHitboxes shows where the server tests shots against a soldier.
func drawHitboxes(soldier game.Soldier) {
	for _, box := range game.Hitboxes(soldier.Position, soldier.Yaw) {
		rl.DrawCapsuleWires(render.Vector(box.A), render.Vector(box.B), box.Radius, 6, 4, zoneColors[box.Zone])
	}
}

func drawCapsule(tuning game.MovementTuning, soldier game.Soldier, tint color.RGBA) {
	feet := render.Vector(soldier.Position.Add(physics.V(0, tuning.CapsuleRadius, 0)))
	head := render.Vector(soldier.Position.Add(physics.V(0, tuning.CapsuleRadius+2*tuning.CapsuleHalfHeight, 0)))
	rl.DrawCapsule(feet, head, tuning.CapsuleRadius, 4, 6, tint)
}
