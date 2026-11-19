package game

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"math"
	"os"

	"ravenfield/internal/physics"
)

// WeaponKind names a weapon. Zero is no weapon: an empty slot of a loadout.
type WeaponKind uint8

const (
	WeaponNone WeaponKind = iota
	WeaponAssaultRifle
	WeaponRifle
	WeaponPistol
	// WeaponKinds counts the kinds, WeaponNone included.
	WeaponKinds
)

var weaponNames = [WeaponKinds]string{"none", "assault rifle", "rifle", "pistol"}

func (k WeaponKind) String() string {
	if k < WeaponKinds {
		return weaponNames[k]
	}
	return fmt.Sprintf("weapon %d", uint8(k))
}

const (
	// The protocol carries a magazine in 8 bits and the spare rounds in 10.
	MaxMagazine = 1<<8 - 1
	MaxReserve  = 1<<10 - 1
	// Timers of weapons count ticks in 8 bits: at most 4.25 s.
	maxWeaponTicks = 1<<8 - 1
)

// WeaponTuning describes a weapon. Angles are in degrees and times in
// seconds, as in the data file. The server and every client must use the
// same values: the client predicts its own weapon.
type WeaponTuning struct {
	// Automatic weapons fire while the trigger is held, the others once per pull.
	Automatic       bool    `json:"automatic"`
	RoundsPerMinute float32 `json:"rounds_per_minute"`
	// Damage is what a hit in the torso takes at close range; hits in the
	// head and the limbs take it times their multipliers. Beyond FalloffStart
	// metres it falls linearly to FalloffDamage of itself at FalloffEnd.
	Damage         float32 `json:"damage"`
	HeadMultiplier float32 `json:"head_multiplier"`
	LimbMultiplier float32 `json:"limb_multiplier"`
	FalloffStart   float32 `json:"falloff_start"`
	FalloffEnd     float32 `json:"falloff_end"`
	FalloffDamage  float32 `json:"falloff_damage"`
	// Range is how far a shot reaches, in metres.
	Range float32 `json:"range"`
	// A soldier spawns with Magazine rounds in the weapon and Reserve spare.
	Magazine   int32   `json:"magazine"`
	Reserve    int32   `json:"reserve"`
	ReloadTime float32 `json:"reload_time"`
	EquipTime  float32 `json:"equip_time"`
	// The spread is a cone around the aim: HipSpread, or AimSpread while
	// aiming, plus MoveSpread at sprint speed and less when slower, AirSpread
	// off the ground, and the bloom of recent shots. A shot adds Bloom, up to
	// MaxBloom; once the weapon could fire again, the bloom fades by
	// BloomRecovery degrees a second, so it grows through a burst.
	HipSpread     float32 `json:"hip_spread"`
	AimSpread     float32 `json:"aim_spread"`
	MoveSpread    float32 `json:"move_spread"`
	AirSpread     float32 `json:"air_spread"`
	Bloom         float32 `json:"bloom"`
	MaxBloom      float32 `json:"max_bloom"`
	BloomRecovery float32 `json:"bloom_recovery"`
	// A shot kicks the aim up by KickPitch and sideways by up to KickYaw; the
	// kick fades at the rate KickRecovery per second.
	KickPitch    float32 `json:"kick_pitch"`
	KickYaw      float32 `json:"kick_yaw"`
	KickRecovery float32 `json:"kick_recovery"`
	// AimZoom narrows the field of view while aiming. Only the client uses it.
	AimZoom float32 `json:"aim_zoom"`
}

// FireInterval is the number of ticks between two shots.
func (w *WeaponTuning) FireInterval() int {
	return ticks(60 / w.RoundsPerMinute)
}

func (w *WeaponTuning) ReloadTicks() int {
	return ticks(w.ReloadTime)
}

func (w *WeaponTuning) EquipTicks() int {
	return ticks(w.EquipTime)
}

// DamageAt is the damage of a torso hit from the given distance.
func (w *WeaponTuning) DamageAt(distance float32) float32 {
	if distance <= w.FalloffStart {
		return w.Damage
	}
	if distance >= w.FalloffEnd {
		return w.Damage * w.FalloffDamage
	}
	share := (distance - w.FalloffStart) / (w.FalloffEnd - w.FalloffStart)
	return w.Damage * (1 - share*(1-w.FalloffDamage))
}

func (w *WeaponTuning) Validate() error {
	inTicks := func(seconds float32) bool {
		return seconds > 0 && ticks(seconds) >= 1 && ticks(seconds) <= maxWeaponTicks
	}
	switch {
	case w.RoundsPerMinute <= 0 || !inTicks(60/w.RoundsPerMinute):
		return fmt.Errorf("rounds per minute must be between %d and %d", 60*TickRate/maxWeaponTicks+1, 60*TickRate)
	case w.Damage <= 0 || w.HeadMultiplier <= 0 || w.LimbMultiplier <= 0:
		return errors.New("damage and its multipliers must be positive")
	case w.FalloffStart < 0 || w.FalloffEnd < w.FalloffStart || w.FalloffDamage < 0 || w.FalloffDamage > 1:
		return errors.New("falloff must start before it ends and keep between 0 and 1 of the damage")
	case w.Range <= 0:
		return errors.New("range must be positive")
	case w.Magazine < 1 || w.Magazine > MaxMagazine || w.Reserve < 0 || w.Reserve > MaxReserve:
		return fmt.Errorf("magazine must hold 1 to %d rounds and the reserve 0 to %d", MaxMagazine, MaxReserve)
	case !inTicks(w.ReloadTime) || !inTicks(w.EquipTime):
		return fmt.Errorf("reload and equip times must be between one tick and %.2f s", float32(maxWeaponTicks)/TickRate)
	case w.HipSpread < 0 || w.AimSpread < 0 || w.MoveSpread < 0 || w.AirSpread < 0 ||
		w.Bloom < 0 || w.MaxBloom < 0 || w.BloomRecovery < 0:
		return errors.New("spread and bloom must not be negative")
	case w.KickPitch < 0 || w.KickYaw < 0 || w.KickRecovery < 0:
		return errors.New("kick must not be negative")
	case w.AimZoom <= 0 || w.AimZoom > 1:
		return errors.New("aim zoom must be in (0, 1]")
	}
	return nil
}

// WeaponSet is the tuning of every weapon. Its data file names the weapons by
// key and may give only the values it changes.
type WeaponSet struct {
	AssaultRifle WeaponTuning `json:"assault_rifle"`
	Rifle        WeaponTuning `json:"rifle"`
	Pistol       WeaponTuning `json:"pistol"`
}

// DefaultWeapons is the arsenal of the specification (6.1): an automatic
// assault rifle for middle range, a precise rifle that hits hard and a pistol
// that comes out quickly.
func DefaultWeapons() WeaponSet {
	return WeaponSet{
		AssaultRifle: WeaponTuning{
			Automatic: true, RoundsPerMinute: 600, Range: 300, Magazine: 30, Reserve: 120, ReloadTime: 2.2, EquipTime: 0.6,
			Damage: 25, HeadMultiplier: 2, LimbMultiplier: 0.75, FalloffStart: 30, FalloffEnd: 80, FalloffDamage: 0.6,
			HipSpread: 2, AimSpread: 0.35, MoveSpread: 2, AirSpread: 4, Bloom: 0.3, MaxBloom: 3, BloomRecovery: 6,
			KickPitch: 0.9, KickYaw: 0.35, KickRecovery: 5, AimZoom: 0.75,
		},
		Rifle: WeaponTuning{
			RoundsPerMinute: 200, Range: 500, Magazine: 10, Reserve: 40, ReloadTime: 2.6, EquipTime: 0.8,
			Damage: 55, HeadMultiplier: 2, LimbMultiplier: 0.75, FalloffStart: 100, FalloffEnd: 300, FalloffDamage: 0.8,
			HipSpread: 3, AimSpread: 0.1, MoveSpread: 3, AirSpread: 6, Bloom: 1, MaxBloom: 2, BloomRecovery: 4,
			KickPitch: 3, KickYaw: 0.6, KickRecovery: 6, AimZoom: 0.5,
		},
		Pistol: WeaponTuning{
			RoundsPerMinute: 400, Range: 150, Magazine: 12, Reserve: 48, ReloadTime: 1.5, EquipTime: 0.35,
			Damage: 30, HeadMultiplier: 2, LimbMultiplier: 0.75, FalloffStart: 15, FalloffEnd: 40, FalloffDamage: 0.5,
			HipSpread: 1.5, AimSpread: 0.6, MoveSpread: 1.5, AirSpread: 3, Bloom: 0.6, MaxBloom: 2.5, BloomRecovery: 8,
			KickPitch: 1.5, KickYaw: 0.4, KickRecovery: 8, AimZoom: 0.85,
		},
	}
}

// Get returns the tuning of a kind, or nil for none.
func (s *WeaponSet) Get(kind WeaponKind) *WeaponTuning {
	switch kind {
	case WeaponAssaultRifle:
		return &s.AssaultRifle
	case WeaponRifle:
		return &s.Rifle
	case WeaponPistol:
		return &s.Pistol
	}
	return nil
}

func (s *WeaponSet) Validate() error {
	for kind := WeaponNone + 1; kind < WeaponKinds; kind++ {
		if err := s.Get(kind).Validate(); err != nil {
			return fmt.Errorf("%s: %w", kind, err)
		}
	}
	return nil
}

// Hash covers every field of every weapon.
func (s WeaponSet) Hash() uint64 {
	hash := fnv.New64a()
	_ = binary.Write(hash, binary.LittleEndian, s)
	return hash.Sum64()
}

// LoadWeapons reads a JSON file on top of the defaults.
func LoadWeapons(path string) (WeaponSet, error) {
	weapons := DefaultWeapons()
	if err := loadJSON(path, &weapons); err != nil {
		return WeaponSet{}, fmt.Errorf("weapons %q: %w", path, err)
	}
	if err := weapons.Validate(); err != nil {
		return WeaponSet{}, fmt.Errorf("weapons %q: %w", path, err)
	}
	return weapons, nil
}

func loadJSON(path string, value any) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	return decoder.Decode(value)
}

// MaxLoadout is how many weapons a soldier carries.
const MaxLoadout = 3

// Loadout is the weapons a soldier spawns with, by slot.
type Loadout [MaxLoadout]WeaponKind

// DefaultLoadout carries all three weapons until classes choose (stage 3).
func DefaultLoadout() Loadout {
	return Loadout{WeaponAssaultRifle, WeaponRifle, WeaponPistol}
}

// WeaponAction is what keeps a weapon from firing for a while.
type WeaponAction uint8

const (
	WeaponReady WeaponAction = iota
	WeaponEquipping
	WeaponReloading
)

type Ammo struct {
	Magazine uint8
	Reserve  uint16
}

// Arsenal is the weapons a soldier carries and their state. Only the server
// and the soldier's own player know it; the other players see the weapon in
// its hands. Spread and kick are in radians.
type Arsenal struct {
	Weapons Loadout
	Ammo    [MaxLoadout]Ammo
	Current uint8
	Action  WeaponAction
	// ActionTicks is how many ticks the action has left, Cooldown how many
	// until the weapon fires again.
	ActionTicks uint8
	Cooldown    uint8
	// Trigger is set from a shot until the trigger is released: a weapon that
	// is not automatic fires once per pull.
	Trigger bool
	Bloom   float32
	// The kick turns the aim of the next shots, and the view with it.
	KickPitch float32
	KickYaw   float32
}

// NewArsenal arms a soldier with full magazines, the first weapon in hand.
func NewArsenal(loadout Loadout, weapons *WeaponSet) Arsenal {
	arsenal := Arsenal{Weapons: loadout}
	for i, kind := range loadout {
		if tuning := weapons.Get(kind); tuning != nil {
			arsenal.Ammo[i] = Ammo{Magazine: uint8(tuning.Magazine), Reserve: uint16(tuning.Reserve)}
		}
	}
	return arsenal
}

// Holding is what a client knows of another soldier's arsenal: the weapon in
// its hands.
func Holding(kind WeaponKind) Arsenal {
	return Arsenal{Weapons: Loadout{kind}}
}

// Weapon is the weapon in the soldier's hands.
func (a *Arsenal) Weapon() WeaponKind {
	if int(a.Current) >= MaxLoadout {
		return WeaponNone
	}
	return a.Weapons[a.Current]
}

// Agrees reports whether two states are the same, the fading spread and kick
// to within rounding: a client on another processor may compute them a
// little differently.
func (a *Arsenal) Agrees(other *Arsenal) bool {
	const limit = 1e-5
	near := func(x, y float32) bool { return float32(math.Abs(float64(x-y))) <= limit }
	return a.Weapons == other.Weapons && a.Ammo == other.Ammo && a.Current == other.Current &&
		a.Action == other.Action && a.ActionTicks == other.ActionTicks && a.Cooldown == other.Cooldown &&
		a.Trigger == other.Trigger && near(a.Bloom, other.Bloom) && near(a.KickPitch, other.KickPitch) &&
		near(a.KickYaw, other.KickYaw)
}

// WeaponEvents tell what a weapon did in a tick, for the hit test of the
// server and the effects of the player's own client.
type WeaponEvents uint8

const (
	EventFired WeaponEvents = 1 << iota
	// EventDryFire is a pull of the trigger with no rounds left at all.
	EventDryFire
	EventReloadStarted
	EventReloaded
	EventEquipStarted
)

func (e WeaponEvents) Has(event WeaponEvents) bool {
	return e&event != 0
}

// Shot is a round fired from the soldier's eye along Direction, which has the
// kick and the spread in it.
type Shot struct {
	Weapon    WeaponKind
	Origin    physics.Vec3
	Direction physics.Vec3
}

type WeaponStep struct {
	Events WeaponEvents
	// Shot is set with EventFired; a weapon fires at most once a tick.
	Shot Shot
}

// Motion is how the soldier moves, for the spread: Speed is its share of the
// sprint speed.
type Motion struct {
	Speed    float32
	Airborne bool
}

const (
	// maxKick bounds how far the kick of a long burst turns the aim.
	maxKick = 12 * math.Pi / 180
	// A kicked aim stops short of straight up or down.
	maxShotPitch = math.Pi/2 - 0.01
	// Kick below this much is gone, so that a calm weapon is exactly calm.
	kickRest = 1e-6
)

// Step works the weapons for a tick of the command, after the soldier moved.
// The order is: the timers run, a change of weapon starts, an action ends,
// a reload starts, then the weapon fires if it may. seed makes the spread
// repeatable (ShotSeed).
func (a *Arsenal) Step(weapons *WeaponSet, command InputCommand, motion Motion, seed uint64) WeaponStep {
	var step WeaponStep
	tuning := weapons.Get(a.Weapon())
	a.recover(tuning)
	if a.Cooldown > 0 {
		a.Cooldown--
	}
	if slot := command.Weapon; int(slot) < MaxLoadout && slot != a.Current && a.Weapons[slot] != WeaponNone {
		a.Current, tuning = slot, weapons.Get(a.Weapons[slot])
		a.Action, a.ActionTicks, a.Bloom = WeaponEquipping, uint8(tuning.EquipTicks()), 0
		step.Events |= EventEquipStarted
	} else if a.Action != WeaponReady {
		if a.ActionTicks--; a.ActionTicks == 0 {
			if a.Action == WeaponReloading {
				a.refill(tuning)
				step.Events |= EventReloaded
			}
			a.Action = WeaponReady
		}
	}
	if tuning == nil {
		return step
	}
	fire := command.Buttons.Has(ButtonFire)
	if !fire {
		a.Trigger = false
	}
	ammo := &a.Ammo[a.Current]
	if a.Action == WeaponReady && command.Buttons.Has(ButtonReload) && int32(ammo.Magazine) < tuning.Magazine && ammo.Reserve > 0 {
		a.startReload(tuning)
		step.Events |= EventReloadStarted
	}
	if a.Action != WeaponReady || !fire || a.Cooldown > 0 || (a.Trigger && !tuning.Automatic) {
		return step
	}
	if ammo.Magazine == 0 {
		switch {
		case ammo.Reserve > 0:
			a.startReload(tuning)
			step.Events |= EventReloadStarted
		case !a.Trigger:
			step.Events |= EventDryFire
		}
		a.Trigger = true
		return step
	}
	ammo.Magazine--
	a.Cooldown, a.Trigger = uint8(tuning.FireInterval()), true
	step.Events |= EventFired
	step.Shot = a.shoot(tuning, command, motion, seed)
	return step
}

func (a *Arsenal) startReload(tuning *WeaponTuning) {
	a.Action, a.ActionTicks = WeaponReloading, uint8(tuning.ReloadTicks())
}

func (a *Arsenal) refill(tuning *WeaponTuning) {
	ammo := &a.Ammo[a.Current]
	moved := min(uint16(tuning.Magazine)-uint16(ammo.Magazine), ammo.Reserve)
	ammo.Magazine += uint8(moved)
	ammo.Reserve -= moved
}

// recover fades the kick of the weapon in hand for a tick, and its bloom
// unless it is still cooling down from a shot.
func (a *Arsenal) recover(tuning *WeaponTuning) {
	if tuning == nil {
		a.Bloom, a.KickPitch, a.KickYaw = 0, 0, 0
		return
	}
	if a.Cooldown == 0 {
		a.Bloom = max(0, a.Bloom-radians(tuning.BloomRecovery)/TickRate)
	}
	fade := float32(math.Exp(-float64(tuning.KickRecovery) / TickRate))
	a.KickPitch, a.KickYaw = rest(a.KickPitch*fade), rest(a.KickYaw*fade)
}

func rest(kick float32) float32 {
	if float32(math.Abs(float64(kick))) < kickRest {
		return 0
	}
	return kick
}

// Spread is the angle, in radians, within which the next shot of the weapon
// in hand scatters.
func (a *Arsenal) Spread(weapons *WeaponSet, aiming bool, motion Motion) float32 {
	tuning := weapons.Get(a.Weapon())
	if tuning == nil {
		return 0
	}
	return a.spread(tuning, aiming, motion)
}

func (a *Arsenal) spread(tuning *WeaponTuning, aiming bool, motion Motion) float32 {
	spread := tuning.HipSpread
	if aiming {
		spread = tuning.AimSpread
	}
	spread += tuning.MoveSpread * max(0, min(1, motion.Speed))
	if motion.Airborne {
		spread += tuning.AirSpread
	}
	return radians(spread) + a.Bloom
}

// shoot aims a shot along the view turned by the kick, scatters it within
// the spread, and kicks and blooms the weapon for the next one.
func (a *Arsenal) shoot(tuning *WeaponTuning, command InputCommand, motion Motion, seed uint64) Shot {
	angle := a.spread(tuning, command.Buttons.Has(ButtonAim), motion)
	yaw := command.YawRadians() + a.KickYaw
	pitch := max(-maxShotPitch, min(maxShotPitch, command.PitchRadians()+a.KickPitch))
	random := shotRandom(seed)
	direction := scatter(yaw, pitch, angle*float32Sqrt(random.next()), 2*math.Pi*random.next())
	a.Bloom = min(radians(tuning.MaxBloom), a.Bloom+radians(tuning.Bloom))
	a.KickPitch = min(maxKick, a.KickPitch+radians(tuning.KickPitch))
	a.KickYaw = max(-maxKick, min(maxKick, a.KickYaw+radians(tuning.KickYaw)*(2*random.next()-1)))
	return Shot{Weapon: a.Weapon(), Direction: direction}
}

// scatter turns the view direction by angle, towards the side given by turn:
// zero to the right, a quarter turn up.
func scatter(yaw, pitch, angle, turn float32) physics.Vec3 {
	forward := ViewDirection(yaw, pitch)
	if angle == 0 {
		return forward
	}
	sinYaw, cosYaw := float32Sin(yaw), float32Cos(yaw)
	sinPitch, cosPitch := float32Sin(pitch), float32Cos(pitch)
	right := physics.V(cosYaw, 0, sinYaw)
	up := physics.V(-sinYaw*sinPitch, cosPitch, cosYaw*sinPitch)
	offset := float32(math.Tan(float64(angle)))
	direction := forward.Add(right.Mul(offset * float32Cos(turn))).Add(up.Mul(offset * float32Sin(turn)))
	return direction.Mul(1 / float32Sqrt(direction.Dot(direction)))
}

// ShotSeed makes the spread of a shot repeatable: the client predicts its own
// shots with the spread the server uses.
func ShotSeed(match uint64, soldier SoldierID, tick Tick) uint64 {
	return mix64(match ^ uint64(soldier)<<32 ^ uint64(tick))
}

// shotRandom draws numbers in [0, 1) from a seed, by SplitMix64.
type shotRandom uint64

func (r *shotRandom) next() float32 {
	*r += 0x9E3779B97F4A7C15
	return float32(mix64(uint64(*r))>>40) / (1 << 24)
}

func mix64(x uint64) uint64 {
	x ^= x >> 30
	x *= 0xBF58476D1CE4E5B9
	x ^= x >> 27
	x *= 0x94D049BB133111EB
	return x ^ x>>31
}

func radians(degrees float32) float32 {
	return degrees * (math.Pi / 180)
}

func ticks(seconds float32) int {
	return int(math.Round(float64(seconds) * TickRate))
}
