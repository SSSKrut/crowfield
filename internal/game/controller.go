package game

import "ravenfield/internal/physics"

type PlayerInput struct {
	Forward float32
	Right   float32
	Jump    bool
	Sprint  bool
	Yaw     float32
}

type CharacterController struct {
	character *physics.Character
	velocity  physics.Vec3
	spawn     physics.Vec3
}

func NewCharacterController(character *physics.Character, spawn physics.Vec3) *CharacterController {
	return &CharacterController{character: character, spawn: spawn}
}

func (c *CharacterController) Update(input PlayerInput, deltaTime float32) error {
	grounded, err := c.character.IsGrounded()
	if err != nil {
		return err
	}
	speed := float32(5)
	if input.Sprint {
		speed = 8
	}
	forward := physics.V(float32Sin(input.Yaw), 0, -float32Cos(input.Yaw))
	right := physics.V(float32Cos(input.Yaw), 0, float32Sin(input.Yaw))
	horizontal := forward.Mul(input.Forward).Add(right.Mul(input.Right))
	lengthSquared := horizontal.X*horizontal.X + horizontal.Z*horizontal.Z
	if lengthSquared > 1 {
		factor := float32(1) / float32Sqrt(lengthSquared)
		horizontal = horizontal.Mul(factor)
	}
	c.velocity.X = horizontal.X * speed
	c.velocity.Z = horizontal.Z * speed
	if grounded && c.velocity.Y <= 0 {
		c.velocity.Y = -0.5
		if input.Jump {
			c.velocity.Y = 6
		}
	} else {
		c.velocity.Y -= 9.81 * deltaTime
	}
	if err := c.character.SetLinearVelocity(c.velocity); err != nil {
		return err
	}
	return c.character.Update(deltaTime)
}

func (c *CharacterController) Reset() error {
	c.velocity = physics.Vec3{}
	if err := c.character.SetPosition(c.spawn); err != nil {
		return err
	}
	return c.character.SetLinearVelocity(c.velocity)
}

func (c *CharacterController) Position() (physics.Vec3, error) {
	return c.character.Position()
}

func (c *CharacterController) Velocity() physics.Vec3 {
	return c.velocity
}
