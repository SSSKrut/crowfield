package protocol

import (
	"errors"
	"fmt"
	"math"

	"ravenfield/internal/game"
)

const (
	magazineBits    = 8
	reserveBits     = 10
	currentBits     = 2
	actionBits      = 2
	actionTicksBits = 8
	cooldownBits    = 8
)

// arsenalBits is the size of a player's own weapons in the private part: every
// slot's weapon, and the ammo of the occupied ones; the action, with its time
// left unless the weapon is ready; the cooldown, the trigger, and the bloom
// and kick at full precision, which the prediction continues from.
func arsenalBits(a *game.Arsenal) int {
	bits := game.MaxLoadout*weaponBits + currentBits + actionBits + cooldownBits + 1 + 3*32
	for _, kind := range a.Weapons {
		if kind != game.WeaponNone {
			bits += magazineBits + reserveBits
		}
	}
	if a.Action != game.WeaponReady {
		bits += actionTicksBits
	}
	return bits
}

// validateArsenal accepts what the encoding carries, and only in its one form:
// an empty slot has no ammo, and only a busy weapon has time left.
func validateArsenal(a *game.Arsenal) error {
	for i, kind := range a.Weapons {
		switch {
		case kind >= game.WeaponKinds:
			return fmt.Errorf("unknown weapon %d", kind)
		case kind == game.WeaponNone && a.Ammo[i] != (game.Ammo{}):
			return errors.New("an empty weapon slot has ammo")
		case a.Ammo[i].Reserve >= 1<<reserveBits:
			return fmt.Errorf("%d spare rounds do not fit", a.Ammo[i].Reserve)
		}
	}
	switch {
	case a.Current >= game.MaxLoadout:
		return fmt.Errorf("weapon slot %d is out of range", a.Current)
	case a.Action > game.WeaponReloading:
		return fmt.Errorf("unknown weapon action %d", a.Action)
	case (a.Action == game.WeaponReady) != (a.ActionTicks == 0):
		return errors.New("only a busy weapon has time left")
	}
	for _, value := range [3]float32{a.Bloom, a.KickPitch, a.KickYaw} {
		if math.IsNaN(float64(value)) || math.IsInf(float64(value), 0) {
			return ErrInvalidFloat
		}
	}
	return nil
}

func writeArsenal(w *BitWriter, a *game.Arsenal) {
	for i, kind := range a.Weapons {
		w.WriteBits(uint32(kind), weaponBits)
		if kind != game.WeaponNone {
			w.WriteBits(uint32(a.Ammo[i].Magazine), magazineBits)
			w.WriteBits(uint32(a.Ammo[i].Reserve), reserveBits)
		}
	}
	w.WriteBits(uint32(a.Current), currentBits)
	w.WriteBits(uint32(a.Action), actionBits)
	if a.Action != game.WeaponReady {
		w.WriteBits(uint32(a.ActionTicks), actionTicksBits)
	}
	w.WriteBits(uint32(a.Cooldown), cooldownBits)
	w.WriteBool(a.Trigger)
	w.WriteFloat32(a.Bloom)
	w.WriteFloat32(a.KickPitch)
	w.WriteFloat32(a.KickYaw)
}

func readArsenal(r *BitReader, a *game.Arsenal) {
	*a = game.Arsenal{}
	for i := range a.Weapons {
		a.Weapons[i] = game.WeaponKind(r.ReadBits(weaponBits))
		if a.Weapons[i] != game.WeaponNone {
			a.Ammo[i].Magazine = uint8(r.ReadBits(magazineBits))
			a.Ammo[i].Reserve = uint16(r.ReadBits(reserveBits))
		}
	}
	a.Current = uint8(r.ReadBits(currentBits))
	a.Action = game.WeaponAction(r.ReadBits(actionBits))
	if a.Action != game.WeaponReady {
		a.ActionTicks = uint8(r.ReadBits(actionTicksBits))
	}
	a.Cooldown = uint8(r.ReadBits(cooldownBits))
	a.Trigger = r.ReadBool()
	a.Bloom = r.ReadFloat32()
	a.KickPitch = r.ReadFloat32()
	a.KickYaw = r.ReadFloat32()
	if r.Err() == nil {
		if err := validateArsenal(a); err != nil {
			r.Fail(err)
		}
	}
}
