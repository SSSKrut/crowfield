package game

import (
	"math"

	"ravenfield/internal/physics"
)

// CharacterController moves a human-controlled soldier with a physics capsule.
type CharacterController struct {
	character *physics.Character
	tuning    MovementTuning
}

// MovementState is the capsule's internal state after a tick: the ground state
// and the contacts that the next tick reads. Position and velocity alone do not
// determine them, so a replay that restores only the soldier drifts by
// centimetres on stairs and slopes.
type MovementState struct {
	data []byte
}

func NewCharacterController(world *physics.World, tuning MovementTuning, feet physics.Vec3) (*CharacterController, error) {
	if err := tuning.Validate(); err != nil {
		return nil, err
	}
	character, err := world.CreateCharacter(physics.CharacterDesc{
		Position:   feet.Add(physics.V(0, tuning.CenterHeight(), 0)),
		HalfHeight: tuning.CapsuleHalfHeight, Radius: tuning.CapsuleRadius,
		MaxSlopeRadians: tuning.MaxSlopeDegrees * math.Pi / 180,
		MaxStrength:     tuning.PushStrength,
	})
	if err != nil {
		return nil, err
	}
	return &CharacterController{character: character, tuning: tuning}, nil
}

func (c *CharacterController) Close() error {
	return c.character.Close()
}

func (c *CharacterController) Step(soldier *Soldier, command InputCommand) error {
	grounded, err := c.character.IsGrounded()
	if err != nil {
		return err
	}
	soldier.Yaw = command.YawRadians()
	soldier.Pitch = command.PitchRadians()
	speed := c.tuning.WalkSpeed
	if command.Buttons.Has(ButtonSprint) {
		speed = c.tuning.SprintSpeed
	}
	forwardAxis, rightAxis := command.Move()
	forward := physics.V(float32Sin(soldier.Yaw), 0, -float32Cos(soldier.Yaw))
	right := physics.V(float32Cos(soldier.Yaw), 0, float32Sin(soldier.Yaw))
	horizontal := forward.Mul(forwardAxis).Add(right.Mul(rightAxis))
	lengthSquared := horizontal.X*horizontal.X + horizontal.Z*horizontal.Z
	if lengthSquared > 1 {
		factor := float32(1) / float32Sqrt(lengthSquared)
		horizontal = horizontal.Mul(factor)
	}
	velocity := soldier.Velocity
	velocity.X = horizontal.X * speed
	velocity.Z = horizontal.Z * speed
	if grounded && velocity.Y <= 0 {
		velocity.Y = -c.tuning.GroundStickSpeed
		if command.Buttons.Has(ButtonJump) {
			velocity.Y = c.tuning.JumpSpeed
		}
	} else {
		velocity.Y -= c.tuning.Gravity * TickDelta
	}
	if err := c.character.SetLinearVelocity(velocity); err != nil {
		return err
	}
	if err := c.character.Update(TickDelta); err != nil {
		return err
	}
	center, err := c.character.Position()
	if err != nil {
		return err
	}
	soldier.Position = center.Sub(physics.V(0, c.tuning.CenterHeight(), 0))
	soldier.Velocity = velocity
	soldier.Grounded, err = c.character.IsGrounded()
	return err
}

// Teleport places the soldier without a movement history, for example on spawn.
func (c *CharacterController) Teleport(soldier *Soldier, feet physics.Vec3) error {
	soldier.Position = feet
	soldier.Velocity = physics.Vec3{}
	if err := c.character.SetPosition(feet.Add(physics.V(0, c.tuning.CenterHeight(), 0))); err != nil {
		return err
	}
	if err := c.character.SetLinearVelocity(soldier.Velocity); err != nil {
		return err
	}
	if err := c.character.RefreshContacts(); err != nil {
		return err
	}
	soldier.Grounded, _ = c.character.IsGrounded()
	return nil
}

func (c *CharacterController) SaveState(state *MovementState) error {
	data, err := c.character.SaveState(state.data)
	state.data = data
	return err
}

// Restore returns the capsule to a saved tick before replaying commands. With
// the soldier saved for the same tick the replay is exact. If the soldier was
// moved since, as by a server correction, its position wins and the contacts
// still come from the saved state.
func (c *CharacterController) Restore(soldier *Soldier, state *MovementState) error {
	if err := c.character.RestoreState(state.data); err != nil {
		return err
	}
	center, err := c.character.Position()
	if err != nil {
		return err
	}
	if offset := physics.V(0, c.tuning.CenterHeight(), 0); soldier.Position != center.Sub(offset) {
		if err := c.character.SetPosition(soldier.Position.Add(offset)); err != nil {
			return err
		}
	}
	soldier.Grounded, err = c.character.IsGrounded()
	return err
}
