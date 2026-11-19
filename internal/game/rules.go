package game

import (
	"encoding/binary"
	"hash/fnv"
)

// Rules are the parameters both ends of a connection must share, because the
// client predicts with them: movement and weapons. The server sends their
// hash in Welcome, and a client with other rules refuses to play.
type Rules struct {
	Movement MovementTuning
	Weapons  WeaponSet
}

func DefaultRules() Rules {
	return Rules{Movement: DefaultMovementTuning(), Weapons: DefaultWeapons()}
}

// LoadRules reads the movement and the weapon files on top of the defaults;
// an empty path keeps the defaults of its part.
func LoadRules(movement, weapons string) (Rules, error) {
	rules := DefaultRules()
	var err error
	if movement != "" {
		if rules.Movement, err = LoadMovementTuning(movement); err != nil {
			return Rules{}, err
		}
	}
	if weapons != "" {
		if rules.Weapons, err = LoadWeapons(weapons); err != nil {
			return Rules{}, err
		}
	}
	return rules, nil
}

func (r *Rules) Validate() error {
	if err := r.Movement.Validate(); err != nil {
		return err
	}
	return r.Weapons.Validate()
}

func (r *Rules) Hash() uint64 {
	hash := fnv.New64a()
	_, _ = hash.Write(binary.LittleEndian.AppendUint64(nil, r.Movement.Hash()))
	_, _ = hash.Write(binary.LittleEndian.AppendUint64(nil, r.Weapons.Hash()))
	return hash.Sum64()
}
