package animation

import "ravenfield/internal/physics"

func (c *CharacterModel) RagdollDebug() ([]physics.RagdollPart, []physics.Transform, bool) {
	if c.ragdoll == nil {
		return nil, nil, false
	}
	transforms, err := c.ragdoll.Transforms()
	if err != nil {
		return nil, nil, false
	}
	return c.parts, transforms, true
}

func (c *CharacterModel) RagdollActive() bool {
	if c.ragdoll == nil {
		return false
	}
	active, _ := c.ragdoll.IsActive()
	return active
}
