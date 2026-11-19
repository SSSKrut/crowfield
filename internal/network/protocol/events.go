package protocol

import (
	"errors"
	"fmt"

	"ravenfield/internal/game"
)

// The events of combat go on the reliable events channel, only to the
// players they concern (ARCHITECTURE.md, 6.3): every client sees hits and
// deaths of all soldiers from the snapshots, and the events add what only
// the people involved need, and what a kill feed needs.

const (
	zoneBits   = 2
	damageBits = 8
	// A damage carries the yaw the shot travelled along in 8 bits.
	damageYawBits = 8
)

// HitConfirm tells a shooter that its shot hurt a soldier, for the hit
// marker; Killed when the shot killed it.
type HitConfirm struct {
	Tick   game.Tick
	Victim game.SoldierID
	Zone   game.HitZone
	Damage uint8
	Killed bool
}

func (*HitConfirm) Type() MessageType { return MessageHitConfirm }

func (m *HitConfirm) Encode(dst []byte) ([]byte, error) {
	if err := checkSoldier("victim", m.Victim); err != nil {
		return dst, err
	}
	if m.Zone >= 1<<zoneBits {
		return dst, fmt.Errorf("unknown zone %d", m.Zone)
	}
	w := startWriting(dst, MessageHitConfirm)
	w.WriteBits(uint32(m.Tick), 32)
	w.WriteBits(uint32(m.Victim), 16)
	w.WriteBits(uint32(m.Zone), zoneBits)
	w.WriteBits(uint32(m.Damage), damageBits)
	w.WriteBool(m.Killed)
	return w.Bytes(), nil
}

func (m *HitConfirm) Decode(data []byte) error {
	r := startReading(data, MessageHitConfirm)
	m.Tick = game.Tick(r.ReadBits(32))
	m.Victim = readSoldier(&r)
	m.Zone = game.HitZone(r.ReadBits(zoneBits))
	m.Damage = uint8(r.ReadBits(damageBits))
	m.Killed = r.ReadBool()
	return r.Finish()
}

// Damage tells a player that its soldier was hurt: by whom, and from where,
// as the yaw the shot travelled along, in 256 steps of a turn.
type Damage struct {
	Tick     game.Tick
	Attacker game.SoldierID
	Yaw      uint8
	Zone     game.HitZone
	Damage   uint8
}

func (*Damage) Type() MessageType { return MessageDamage }

func (m *Damage) Encode(dst []byte) ([]byte, error) {
	if err := checkSoldier("attacker", m.Attacker); err != nil {
		return dst, err
	}
	if m.Zone >= 1<<zoneBits {
		return dst, fmt.Errorf("unknown zone %d", m.Zone)
	}
	w := startWriting(dst, MessageDamage)
	w.WriteBits(uint32(m.Tick), 32)
	w.WriteBits(uint32(m.Attacker), 16)
	w.WriteBits(uint32(m.Yaw), damageYawBits)
	w.WriteBits(uint32(m.Zone), zoneBits)
	w.WriteBits(uint32(m.Damage), damageBits)
	return w.Bytes(), nil
}

func (m *Damage) Decode(data []byte) error {
	r := startReading(data, MessageDamage)
	m.Tick = game.Tick(r.ReadBits(32))
	m.Attacker = readSoldier(&r)
	m.Yaw = uint8(r.ReadBits(damageYawBits))
	m.Zone = game.HitZone(r.ReadBits(zoneBits))
	m.Damage = uint8(r.ReadBits(damageBits))
	return r.Finish()
}

// Death tells every player of a death a human took part in, for the kill
// feed and the death screen. Names come with it: clients know soldiers, not
// whose they are.
type Death struct {
	Tick       game.Tick
	Victim     game.SoldierID
	Killer     game.SoldierID
	VictimTeam game.Team
	KillerTeam game.Team
	VictimName string
	KillerName string
	Weapon     game.WeaponKind
	Zone       game.HitZone
}

func (*Death) Type() MessageType { return MessageDeath }

func (m *Death) Encode(dst []byte) ([]byte, error) {
	for _, check := range []error{
		checkSoldier("victim", m.Victim), checkSoldier("killer", m.Killer),
		checkText("victim name", m.VictimName, MaxNameBytes), checkText("killer name", m.KillerName, MaxNameBytes),
	} {
		if check != nil {
			return dst, check
		}
	}
	if m.VictimTeam > game.TeamRed || m.KillerTeam > game.TeamRed || m.Weapon >= 1<<weaponBits || m.Zone >= 1<<zoneBits {
		return dst, errors.New("death with a team, weapon or zone out of range")
	}
	w := startWriting(dst, MessageDeath)
	w.WriteBits(uint32(m.Tick), 32)
	w.WriteBits(uint32(m.Victim), 16)
	w.WriteBits(uint32(m.Killer), 16)
	w.WriteBits(uint32(m.VictimTeam), teamBits)
	w.WriteBits(uint32(m.KillerTeam), teamBits)
	w.WriteString(m.VictimName, nameLengthBits)
	w.WriteString(m.KillerName, nameLengthBits)
	w.WriteBits(uint32(m.Weapon), weaponBits)
	w.WriteBits(uint32(m.Zone), zoneBits)
	return w.Bytes(), nil
}

func (m *Death) Decode(data []byte) error {
	r := startReading(data, MessageDeath)
	m.Tick = game.Tick(r.ReadBits(32))
	m.Victim = readSoldier(&r)
	m.Killer = readSoldier(&r)
	m.VictimTeam = game.Team(r.ReadBits(teamBits))
	m.KillerTeam = game.Team(r.ReadBits(teamBits))
	if r.Err() == nil && (m.VictimTeam > game.TeamRed || m.KillerTeam > game.TeamRed) {
		r.Fail(errors.New("unknown team"))
	}
	m.VictimName = r.ReadString(nameLengthBits, MaxNameBytes)
	m.KillerName = r.ReadString(nameLengthBits, MaxNameBytes)
	m.Weapon = game.WeaponKind(r.ReadBits(weaponBits))
	m.Zone = game.HitZone(r.ReadBits(zoneBits))
	return r.Finish()
}

func checkSoldier(role string, id game.SoldierID) error {
	if id.Generation() == 0 {
		return fmt.Errorf("%s %#04x has no generation", role, id)
	}
	return nil
}

func readSoldier(r *BitReader) game.SoldierID {
	id := game.SoldierID(r.ReadBits(16))
	if r.Err() == nil && id.Generation() == 0 {
		r.Fail(fmt.Errorf("soldier %#04x has no generation", id))
	}
	return id
}
