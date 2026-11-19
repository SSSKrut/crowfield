package game

import (
	"errors"
	"testing"
)

func TestSoldierSetAddGetRemove(t *testing.T) {
	set, err := NewSoldierSet(2)
	if err != nil {
		t.Fatal(err)
	}
	human, err := set.Add(Soldier{Team: TeamBlue, Controller: PlayerController(3)})
	if err != nil {
		t.Fatal(err)
	}
	bot, err := set.Add(Soldier{Team: TeamRed, Controller: BotController(40)})
	if err != nil {
		t.Fatal(err)
	}
	if human.Slot() != 0 || bot.Slot() != 1 {
		t.Errorf("slots %d and %d, want 0 and 1", human.Slot(), bot.Slot())
	}
	if soldier := set.Get(human); soldier == nil || soldier.ID != human || soldier.Controller.Player != 3 {
		t.Errorf("human lookup returned %+v", soldier)
	}
	if soldier := set.Get(bot); soldier == nil || soldier.Controller.Kind != ControllerBot || soldier.Controller.Bot != 40 {
		t.Errorf("bot lookup returned %+v", soldier)
	}
	if _, err := set.Add(Soldier{}); !errors.Is(err, ErrNoFreeSlot) {
		t.Errorf("full set returned %v", err)
	}
	var listed []SoldierID
	for soldier := range set.All() {
		listed = append(listed, soldier.ID)
	}
	if len(listed) != 2 || listed[0] != human || listed[1] != bot || set.Len() != 2 {
		t.Errorf("listed %v, len %d", listed, set.Len())
	}
	if !set.Remove(human) || set.Remove(human) {
		t.Error("remove must succeed once")
	}
	if set.Len() != 1 {
		t.Errorf("len %d after removal", set.Len())
	}
	if set.Get(human) != nil {
		t.Error("removed soldier still resolves")
	}
}

func TestSoldierSetReusedSlotGetsNewGeneration(t *testing.T) {
	set, err := NewSoldierSet(1)
	if err != nil {
		t.Fatal(err)
	}
	if set.Get(0) != nil {
		t.Error("zero ID resolves")
	}
	seen := make(map[uint8]bool)
	var previous SoldierID
	for range 2 * maxGeneration {
		id, err := set.Add(Soldier{})
		if err != nil {
			t.Fatal(err)
		}
		if id == 0 || id.Generation() == 0 || id.Slot() != 0 {
			t.Fatalf("invalid id %#04x", id)
		}
		if id == previous || set.Get(previous) != nil {
			t.Fatalf("id %#04x aliases previous %#04x", id, previous)
		}
		seen[id.Generation()] = true
		set.Remove(id)
		previous = id
	}
	if len(seen) != maxGeneration {
		t.Errorf("used %d generations, want %d", len(seen), maxGeneration)
	}
}

func TestNewSoldierSetRejectsBadCapacity(t *testing.T) {
	for _, capacity := range []int{0, -1, MaxSoldiers + 1} {
		if _, err := NewSoldierSet(capacity); err == nil {
			t.Errorf("capacity %d accepted", capacity)
		}
	}
	if _, err := NewSoldierSet(MaxSoldiers); err != nil {
		t.Errorf("max capacity rejected: %v", err)
	}
}
