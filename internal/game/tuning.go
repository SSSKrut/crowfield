package game

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"math"
	"os"
)

// MovementTuning holds the parameters that decide where a human soldier ends
// up after a command, so the client and the server must use the same values.
type MovementTuning struct {
	WalkSpeed         float32 `json:"walk_speed"`
	SprintSpeed       float32 `json:"sprint_speed"`
	JumpSpeed         float32 `json:"jump_speed"`
	Gravity           float32 `json:"gravity"`
	GroundStickSpeed  float32 `json:"ground_stick_speed"`
	CapsuleHalfHeight float32 `json:"capsule_half_height"`
	CapsuleRadius     float32 `json:"capsule_radius"`
	MaxSlopeDegrees   float32 `json:"max_slope_degrees"`
	EyeHeight         float32 `json:"eye_height"`
	PushStrength      float32 `json:"push_strength"`
}

func DefaultMovementTuning() MovementTuning {
	return MovementTuning{
		WalkSpeed: 5, SprintSpeed: 8, JumpSpeed: 6, Gravity: 9.81, GroundStickSpeed: 0.5,
		CapsuleHalfHeight: 0.55, CapsuleRadius: 0.35, MaxSlopeDegrees: 50, EyeHeight: 1.55, PushStrength: 100,
	}
}

// LoadMovementTuning reads a JSON file on top of the defaults, so the file only
// needs the values it changes.
func LoadMovementTuning(path string) (MovementTuning, error) {
	file, err := os.Open(path)
	if err != nil {
		return MovementTuning{}, err
	}
	defer file.Close()
	tuning := DefaultMovementTuning()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&tuning); err != nil {
		return MovementTuning{}, fmt.Errorf("movement tuning %q: %w", path, err)
	}
	if err := tuning.Validate(); err != nil {
		return MovementTuning{}, fmt.Errorf("movement tuning %q: %w", path, err)
	}
	return tuning, nil
}

func (t MovementTuning) Validate() error {
	switch {
	case t.WalkSpeed <= 0 || t.SprintSpeed <= 0:
		return errors.New("walk and sprint speeds must be positive")
	case t.JumpSpeed < 0 || t.GroundStickSpeed < 0:
		return errors.New("jump and ground stick speeds must not be negative")
	case t.PushStrength < 0:
		return errors.New("push strength must not be negative")
	case t.Gravity <= 0:
		return errors.New("gravity must be positive")
	case t.CapsuleHalfHeight <= 0 || t.CapsuleRadius <= 0:
		return errors.New("capsule dimensions must be positive")
	case t.MaxSlopeDegrees <= 0 || t.MaxSlopeDegrees >= 90:
		return errors.New("max slope must be between 0 and 90 degrees")
	case t.EyeHeight <= 0 || t.EyeHeight > 2*t.CenterHeight():
		return errors.New("eye height must be inside the capsule")
	}
	return nil
}

// Hash identifies the tuning. The server sends it in Welcome, and a client with
// a different tuning refuses to play, because its prediction would not match.
func (t MovementTuning) Hash() uint64 {
	hash := fnv.New64a()
	for _, value := range []float32{
		t.WalkSpeed, t.SprintSpeed, t.JumpSpeed, t.Gravity, t.GroundStickSpeed,
		t.CapsuleHalfHeight, t.CapsuleRadius, t.MaxSlopeDegrees, t.EyeHeight, t.PushStrength,
	} {
		_, _ = hash.Write(binary.LittleEndian.AppendUint32(nil, math.Float32bits(value)))
	}
	return hash.Sum64()
}

// CenterHeight is the distance from the feet to the capsule center.
func (t MovementTuning) CenterHeight() float32 {
	return t.CapsuleHalfHeight + t.CapsuleRadius
}
