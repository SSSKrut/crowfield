package animation

import (
	"fmt"
	"math"
	"strings"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const characterModelHeight = float32(1.75)

type CharacterModel struct {
	model       rl.Model
	animations  []rl.ModelAnimation
	bones       map[string]int
	current     int
	frame       float32
	scale       float32
	origin      physics.Vec3
	ragdoll     *physics.Ragdoll
	ragdollPose []rl.Transform
	ragdollRoot physics.Vec3
	ragdollYaw  physics.Quat
	parts       []physics.RagdollPart
	partBones   []string
	partOffsets []physics.Transform
}

func LoadCharacterModel(path string) (*CharacterModel, error) {
	model := rl.LoadModel(path)
	if model.MeshCount == 0 || model.Skeleton.BoneCount == 0 {
		return nil, fmt.Errorf("model %q has no mesh or skeleton", path)
	}
	bindPose := model.Skeleton.GetBindPose()
	if len(bindPose) == 0 {
		rl.UnloadModel(model)
		return nil, fmt.Errorf("model %q has no bind pose", path)
	}
	minY := bindPose[0].Translation.Y
	maxY := minY
	for _, bone := range bindPose[1:] {
		minY = min(minY, bone.Translation.Y)
		maxY = max(maxY, bone.Translation.Y)
	}
	height := maxY - minY
	if height <= 0 {
		rl.UnloadModel(model)
		return nil, fmt.Errorf("model %q has invalid skeleton bounds", path)
	}
	animations := rl.LoadModelAnimations(path)
	if len(animations) == 0 {
		rl.UnloadModel(model)
		return nil, fmt.Errorf("model %q has no animations", path)
	}
	scale := characterModelHeight / height
	character := &CharacterModel{
		model: model, animations: animations, bones: make(map[string]int), scale: scale,
		origin: physics.V(0, -minY*scale, 0),
	}
	for i, bone := range model.Skeleton.GetBones() {
		character.bones[boneName(bone)] = i
	}
	if err := character.selectAnimation("Idle"); err != nil {
		character.Close()
		return nil, err
	}
	rl.UpdateModelAnimation(model, animations[character.current], 0)
	return character, nil
}

func (c *CharacterModel) Close() error {
	if c.ragdoll != nil {
		_ = c.ragdoll.Close()
		c.ragdoll = nil
	}
	rl.UnloadModelAnimations(c.animations)
	rl.UnloadModel(c.model)
	c.animations = nil
	return nil
}

func (c *CharacterModel) Update(deltaTime, speed float32) error {
	if c.ragdoll != nil {
		return c.updateRagdoll()
	}
	name := "Idle"
	if speed >= 6 {
		name = "Running"
	} else if speed >= 0.15 {
		name = "Walking"
	}
	if err := c.selectAnimation(name); err != nil {
		return err
	}
	animation := c.animations[c.current]
	c.frame = float32(math.Mod(float64(c.frame+deltaTime*60), float64(animation.KeyframeCount)))
	rl.UpdateModelAnimation(c.model, animation, c.frame)
	return nil
}

func (c *CharacterModel) Draw(position physics.Vec3, yaw physics.Quat) {
	rl.DrawModelEx(
		c.model, vector(position.Add(c.origin)), rl.NewVector3(0, 1, 0), yawAngle(yaw),
		rl.NewVector3(c.scale, c.scale, c.scale), rl.White,
	)
}

func (c *CharacterModel) IsRagdoll() bool {
	return c.ragdoll != nil
}

func (c *CharacterModel) AnimationName() string {
	return c.animations[c.current].GetName()
}

func (c *CharacterModel) BoneNames() []string {
	names := make([]string, 0, len(c.bones))
	for _, bone := range c.model.Skeleton.GetBones() {
		names = append(names, boneName(bone))
	}
	return names
}

func (c *CharacterModel) Parts() []physics.RagdollPart {
	return c.parts
}

func (c *CharacterModel) selectAnimation(name string) error {
	if c.animations[c.current].GetName() == name {
		return nil
	}
	for i, animation := range c.animations {
		if strings.EqualFold(animation.GetName(), name) {
			c.current = i
			c.frame = 0
			return nil
		}
	}
	return fmt.Errorf("animation %q not found", name)
}

func (c *CharacterModel) bone(name string) (int, rl.Transform, error) {
	index, ok := c.bones[name]
	if !ok {
		return 0, rl.Transform{}, fmt.Errorf("bone %q not found", name)
	}
	return index, c.model.GetCurrentPose()[index], nil
}

func boneName(bone rl.BoneInfo) string {
	bytes := make([]byte, 0, len(bone.Name))
	for _, value := range bone.Name {
		if value == 0 {
			break
		}
		bytes = append(bytes, byte(value))
	}
	return string(bytes)
}

func vector(value physics.Vec3) rl.Vector3 {
	return rl.NewVector3(value.X, value.Y, value.Z)
}

func quaternion(value physics.Quat) rl.Quaternion {
	return rl.NewQuaternion(value.X, value.Y, value.Z, value.W)
}

func yawAngle(value physics.Quat) float32 {
	return float32(2 * math.Atan2(float64(value.Y), float64(value.W)) * 180 / math.Pi)
}
