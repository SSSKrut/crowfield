package game

import (
	"errors"
	"fmt"
	"iter"

	"ravenfield/internal/physics"
)

const MaxPlayers = 16

type PlayerID uint8

type BotID uint16

type Team uint8

const (
	TeamNone Team = iota
	TeamBlue
	TeamRed
)

type ControllerKind uint8

const (
	ControllerNone ControllerKind = iota
	ControllerPlayer
	ControllerBot
)

// Controller tells who drives a soldier. Humans and bots share combat rules,
// but a human moves through InputCommand and a physics capsule, while a bot is
// driven by the server AI directly.
type Controller struct {
	Kind   ControllerKind
	Player PlayerID
	Bot    BotID
}

func PlayerController(id PlayerID) Controller {
	return Controller{Kind: ControllerPlayer, Player: id}
}

func BotController(id BotID) Controller {
	return Controller{Kind: ControllerBot, Bot: id}
}

// Soldier is a combat body in the world. Position is the point between the feet.
type Soldier struct {
	ID         SoldierID
	Team       Team
	Controller Controller
	Alive      bool
	Position   physics.Vec3
	Velocity   physics.Vec3
	Yaw        float32
	Pitch      float32
	Grounded   bool
}

// SoldierID packs a slot into the low 12 bits and a generation into the high 4.
// Generations run from 1 to 15, so the zero ID never refers to a soldier.
type SoldierID uint16

const (
	soldierSlotBits = 12
	MaxSoldiers     = 1 << soldierSlotBits
	maxGeneration   = 1<<(16-soldierSlotBits) - 1
)

func (id SoldierID) Slot() int {
	return int(id & (MaxSoldiers - 1))
}

func (id SoldierID) Generation() uint8 {
	return uint8(id >> soldierSlotBits)
}

var ErrNoFreeSlot = errors.New("no free soldier slot")

// SoldierSet stores soldiers in fixed slots. A removed slot is reused with the
// next generation, so stale IDs stop resolving instead of aliasing a newcomer.
type SoldierSet struct {
	soldiers    []Soldier
	generations []uint8
	free        []int
}

func NewSoldierSet(capacity int) (*SoldierSet, error) {
	if capacity <= 0 || capacity > MaxSoldiers {
		return nil, fmt.Errorf("soldier capacity must be in 1..%d", MaxSoldiers)
	}
	set := &SoldierSet{
		soldiers: make([]Soldier, capacity), generations: make([]uint8, capacity), free: make([]int, capacity),
	}
	for i := range set.free {
		set.free[i] = capacity - 1 - i
	}
	return set, nil
}

func (s *SoldierSet) Add(soldier Soldier) (SoldierID, error) {
	if len(s.free) == 0 {
		return 0, ErrNoFreeSlot
	}
	slot := s.free[len(s.free)-1]
	s.free = s.free[:len(s.free)-1]
	s.generations[slot] = s.generations[slot]%maxGeneration + 1
	soldier.ID = SoldierID(slot) | SoldierID(s.generations[slot])<<soldierSlotBits
	s.soldiers[slot] = soldier
	return soldier.ID, nil
}

func (s *SoldierSet) Remove(id SoldierID) bool {
	soldier := s.Get(id)
	if soldier == nil {
		return false
	}
	*soldier = Soldier{}
	s.free = append(s.free, id.Slot())
	return true
}

// All yields every soldier in slot order.
func (s *SoldierSet) All() iter.Seq[*Soldier] {
	return func(yield func(*Soldier) bool) {
		for i := range s.soldiers {
			if s.soldiers[i].ID != 0 && !yield(&s.soldiers[i]) {
				return
			}
		}
	}
}

func (s *SoldierSet) Len() int {
	return len(s.soldiers) - len(s.free)
}

func (s *SoldierSet) Get(id SoldierID) *Soldier {
	slot := id.Slot()
	if id == 0 || slot >= len(s.soldiers) || s.soldiers[slot].ID != id {
		return nil
	}
	return &s.soldiers[slot]
}
