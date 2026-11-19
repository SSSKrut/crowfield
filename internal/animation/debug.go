package animation

import "ravenfield/internal/physics"

// RagdollDebug returns the parts of a simulated ragdoll and where they are.
func (c *Character) RagdollDebug() ([]physics.RagdollPart, []physics.Transform, bool) {
	if !c.RagdollActive() {
		return nil, nil, false
	}
	transforms, err := c.ragdoll.body.Transforms()
	if err != nil {
		return nil, nil, false
	}
	return c.ragdoll.parts, transforms, true
}
