package game

import (
	"math"
	"reflect"
	"testing"
)

func TestDefaultWeaponsAreValid(t *testing.T) {
	weapons := DefaultWeapons()
	if err := weapons.Validate(); err != nil {
		t.Fatal(err)
	}
	rules := DefaultRules()
	if err := rules.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestWeaponHashChangesWithEveryField(t *testing.T) {
	base := DefaultWeapons()
	if base.Hash() != DefaultWeapons().Hash() {
		t.Fatal("hash is not stable")
	}
	seen := map[uint64]string{base.Hash(): "default"}
	for kind := WeaponNone + 1; kind < WeaponKinds; kind++ {
		value := reflect.ValueOf(base.Get(kind)).Elem()
		for i := range value.NumField() {
			changed := base
			field := reflect.ValueOf(changed.Get(kind)).Elem().Field(i)
			switch field.Kind() {
			case reflect.Bool:
				field.SetBool(!field.Bool())
			case reflect.Int32:
				field.SetInt(field.Int() + 1)
			default:
				field.SetFloat(field.Float() + 0.25)
			}
			name := kind.String() + " " + value.Type().Field(i).Name
			if previous, ok := seen[changed.Hash()]; ok {
				t.Errorf("changing %s gives the same hash as %s", name, previous)
			}
			seen[changed.Hash()] = name
		}
	}
}

func TestRulesHashCoversMovementAndWeapons(t *testing.T) {
	base := DefaultRules()
	moved, armed := base, base
	moved.Movement.WalkSpeed++
	armed.Weapons.Pistol.Damage++
	if base.Hash() == moved.Hash() || base.Hash() == armed.Hash() || moved.Hash() == armed.Hash() {
		t.Error("rules hash misses a change")
	}
}

func TestLoadWeaponsOverridesDefaults(t *testing.T) {
	weapons, err := LoadWeapons(writeTuning(t, `{"rifle": {"damage": 60, "magazine": 5}}`))
	if err != nil {
		t.Fatal(err)
	}
	want := DefaultWeapons()
	want.Rifle.Damage, want.Rifle.Magazine = 60, 5
	if weapons != want {
		t.Errorf("loaded %+v, want %+v", weapons, want)
	}
	for name, content := range map[string]string{
		"unknown weapon": `{"shotgun": {"damage": 60}}`,
		"unknown field":  `{"pistol": {"damge": 60}}`,
		"empty magazine": `{"pistol": {"magazine": 0}}`,
		"huge magazine":  `{"pistol": {"magazine": 300}}`,
		"slow reload":    `{"rifle": {"reload_time": 5}}`,
		"falloff order":  `{"rifle": {"falloff_end": 50}}`,
	} {
		if _, err := LoadWeapons(writeTuning(t, content)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// arsenalTest steps one soldier's weapons the way RunCommand does, standing.
type arsenalTest struct {
	t       *testing.T
	weapons WeaponSet
	arsenal Arsenal
	tick    Tick
}

func newArsenalTest(t *testing.T) *arsenalTest {
	weapons := DefaultWeapons()
	return &arsenalTest{t: t, weapons: weapons, arsenal: NewArsenal(DefaultLoadout(), &weapons)}
}

func (a *arsenalTest) step(buttons Buttons, slot uint8) WeaponStep {
	command := NewInputCommand(a.tick, 0, 0, 0, 0, buttons)
	command.Weapon = slot
	step := a.arsenal.Step(&a.weapons, command, Motion{}, ShotSeed(1, 0x1001, a.tick))
	a.tick++
	return step
}

// run steps the same buttons for count ticks and returns the ticks it fired at,
// counted from the first.
func (a *arsenalTest) run(count int, buttons Buttons, slot uint8) (shots []int, events WeaponEvents) {
	for i := range count {
		step := a.step(buttons, slot)
		events |= step.Events
		if step.Events.Has(EventFired) {
			shots = append(shots, i)
		}
	}
	return shots, events
}

func TestAutomaticFiresAtItsRate(t *testing.T) {
	a := newArsenalTest(t)
	shots, _ := a.run(TickRate, ButtonFire, 0)
	if len(shots) != 10 || shots[0] != 0 || shots[1] != 6 || shots[9] != 54 {
		t.Errorf("an assault rifle held for a second fired at ticks %v, want every 6th from 0", shots)
	}
	if ammo := a.arsenal.Ammo[0]; ammo.Magazine != 20 || ammo.Reserve != 120 {
		t.Errorf("ammo %+v after 10 shots", ammo)
	}
}

func TestSemiAutomaticFiresOncePerPull(t *testing.T) {
	a := newArsenalTest(t)
	a.run(a.weapons.Rifle.EquipTicks(), 0, 1)
	if shots, _ := a.run(TickRate, ButtonFire, 1); len(shots) != 1 {
		t.Fatalf("a rifle held for a second fired %d times", len(shots))
	}
	// A pull during the cooldown fires when the cooldown ends, if still held.
	a.run(1, 0, 1)
	if shots, _ := a.run(1, ButtonFire, 1); len(shots) != 1 {
		t.Fatal("a new pull did not fire")
	}
	a.run(1, 0, 1)
	interval := a.weapons.Rifle.FireInterval()
	if shots, _ := a.run(interval, ButtonFire, 1); len(shots) != 1 || shots[0] != interval-2 {
		t.Errorf("a pull right after a shot fired at %v, want when the cooldown ends", shots)
	}
}

func TestRepeatedCommandsDoNotPullAgain(t *testing.T) {
	a := newArsenalTest(t)
	a.run(a.weapons.Pistol.EquipTicks(), 0, 2)
	command := NewInputCommand(a.tick, 0, 0, 0, 0, ButtonFire|ButtonReload)
	command.Weapon = 2
	fired := 0
	for range TickRate {
		step := a.arsenal.Step(&a.weapons, command, Motion{}, 0)
		if step.Events.Has(EventFired) {
			fired++
		}
		if step.Events.Has(EventReloadStarted) && fired == 0 {
			t.Fatal("reloaded a full magazine")
		}
		command = command.Repeated(command.Tick + 1)
	}
	if fired != 1 {
		t.Errorf("a pistol fired %d times while its command was repeated", fired)
	}
}

func TestEmptyMagazineReloadsOnThePull(t *testing.T) {
	a := newArsenalTest(t)
	reload := a.weapons.AssaultRifle.ReloadTicks()
	shots, events := a.run(30*6+1, ButtonFire, 0)
	if len(shots) != 30 || !events.Has(EventReloadStarted) {
		t.Fatalf("%d shots, events %b: want the magazine emptied and a reload", len(shots), events)
	}
	if a.arsenal.Action != WeaponReloading || int(a.arsenal.ActionTicks) != reload {
		t.Fatalf("action %d with %d ticks left", a.arsenal.Action, a.arsenal.ActionTicks)
	}
	shots, events = a.run(reload, ButtonFire, 0)
	if !events.Has(EventReloaded) || len(shots) != 1 || shots[0] != reload-1 {
		t.Errorf("after the reload: shots %v, events %b; want a shot on the last tick", shots, events)
	}
	if ammo := a.arsenal.Ammo[0]; ammo.Magazine != 29 || ammo.Reserve != 90 {
		t.Errorf("ammo %+v after reloading and one shot", ammo)
	}
}

func TestReloadButtonTopsUpTheMagazine(t *testing.T) {
	a := newArsenalTest(t)
	a.run(5*6, ButtonFire, 0)
	if _, events := a.run(1, ButtonReload, 0); !events.Has(EventReloadStarted) {
		t.Fatal("reload did not start")
	}
	// Fire is ignored while reloading.
	if shots, _ := a.run(a.weapons.AssaultRifle.ReloadTicks()-1, ButtonFire, 0); len(shots) != 0 {
		t.Fatalf("fired %d times while reloading", len(shots))
	}
	if _, events := a.run(1, 0, 0); !events.Has(EventReloaded) {
		t.Fatal("the reload did not end in time")
	}
	if ammo := a.arsenal.Ammo[0]; ammo.Magazine != 30 || ammo.Reserve != 115 {
		t.Errorf("ammo %+v after topping up 5 rounds", ammo)
	}
	if _, events := a.run(1, ButtonReload, 0); events.Has(EventReloadStarted) {
		t.Error("reloaded a full magazine")
	}
}

func TestSwitchingWeaponsTakesTimeAndStopsTheReload(t *testing.T) {
	a := newArsenalTest(t)
	a.run(6, ButtonFire, 0)
	a.run(1, ButtonReload, 0)
	if _, events := a.run(1, ButtonFire, 2); !events.Has(EventEquipStarted) {
		t.Fatal("no switch to the pistol")
	}
	equip := a.weapons.Pistol.EquipTicks()
	shots, _ := a.run(equip, ButtonFire, 2)
	if len(shots) != 1 || shots[0] != equip-1 {
		t.Errorf("pistol shots %v while equipping for %d ticks", shots, equip)
	}
	if a.arsenal.Weapon() != WeaponPistol || a.arsenal.Ammo[0].Magazine != 29 {
		t.Errorf("holding %s, assault rifle ammo %+v: the reload should have stopped", a.arsenal.Weapon(), a.arsenal.Ammo[0])
	}
	if _, events := a.run(1, 0, 7); events != 0 || a.arsenal.Current != 2 {
		t.Errorf("a slot out of the loadout switched to %d", a.arsenal.Current)
	}
}

func TestDryFireOncePerPull(t *testing.T) {
	a := newArsenalTest(t)
	a.arsenal.Ammo[0] = Ammo{}
	_, events := a.run(10, ButtonFire, 0)
	if !events.Has(EventDryFire) || events.Has(EventReloadStarted) {
		t.Fatalf("events %b with no rounds at all", events)
	}
	dry := 0
	for range 3 {
		if step := a.step(0, 0); step.Events != 0 {
			t.Fatal("events without a pull")
		}
		if step := a.step(ButtonFire, 0); step.Events.Has(EventDryFire) {
			dry++
		}
	}
	if dry != 3 {
		t.Errorf("%d dry clicks for 3 pulls", dry)
	}
}

func TestSpreadIsRepeatableAndWithinItsCone(t *testing.T) {
	weapons := DefaultWeapons()
	for _, aim := range []Buttons{0, ButtonAim} {
		widest := 0.0
		for seed := range uint64(200) {
			arsenal := NewArsenal(DefaultLoadout(), &weapons)
			command := NewInputCommand(0, 0, 0, 1, 0.2, ButtonFire|aim)
			first := arsenal.Step(&weapons, command, Motion{}, mix64(seed))
			again := NewArsenal(DefaultLoadout(), &weapons)
			if again.Step(&weapons, command, Motion{}, mix64(seed)).Shot != first.Shot {
				t.Fatal("the same seed scattered differently")
			}
			view := ViewDirection(command.YawRadians(), command.PitchRadians())
			angle := math.Acos(math.Min(1, float64(view.Dot(first.Shot.Direction))))
			widest = math.Max(widest, angle)
		}
		spread := float64(radians(weapons.AssaultRifle.HipSpread))
		if aim != 0 {
			spread = float64(radians(weapons.AssaultRifle.AimSpread))
		}
		if widest > spread*1.01 || widest < spread*0.8 {
			t.Errorf("aim %t: widest shot %.4f rad off, spread %.4f", aim != 0, widest, spread)
		}
	}
}

func TestKickClimbsAndSettles(t *testing.T) {
	a := newArsenalTest(t)
	a.run(TickRate, ButtonFire, 0)
	if a.arsenal.KickPitch < radians(a.weapons.AssaultRifle.KickPitch) || a.arsenal.Bloom == 0 {
		t.Errorf("kick %.4f and bloom %.4f after a burst", a.arsenal.KickPitch, a.arsenal.Bloom)
	}
	a.run(3*TickRate, 0, 0)
	if a.arsenal.KickPitch != 0 || a.arsenal.KickYaw != 0 || a.arsenal.Bloom != 0 {
		t.Errorf("kick %g/%g and bloom %g after 3 s of rest", a.arsenal.KickPitch, a.arsenal.KickYaw, a.arsenal.Bloom)
	}
}

func TestDamageFallsOffWithDistance(t *testing.T) {
	rifle := DefaultWeapons().AssaultRifle
	for _, c := range []struct{ distance, want float32 }{{0, 25}, {30, 25}, {55, 20}, {80, 15}, {500, 15}} {
		if got := rifle.DamageAt(c.distance); math.Abs(float64(got-c.want)) > 1e-4 {
			t.Errorf("damage at %.0f m is %.2f, want %.2f", c.distance, got, c.want)
		}
	}
}
