package client

import (
	"math"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/physics"
)

// predictionHistory covers two seconds, more than any round trip the game is
// played with. A confirmation older than that cannot be replayed and is snapped to.
const predictionHistory = 2 * game.TickRate

const (
	// The server runs the same code, so its state matches the prediction
	// exactly unless a command came late; these limits only absorb rounding.
	acceptedPositionError = 1e-4
	acceptedVelocityError = 1e-3
	// A correction longer than this is a teleport, like a respawn: it is shown
	// at once and the capsule finds its contacts anew.
	teleportDistance = 2
	// The drawn soldier catches up with a correction with this time constant,
	// about 95 % within 150 ms.
	smoothingTime = 0.05
)

type predictedTick struct {
	tick    game.Tick
	command game.InputCommand
	soldier game.Soldier
	state   game.MovementState
	stepped bool
}

// predictor moves the player's own soldier and works its weapons as soon as a
// command is made, with the code of the server, and corrects them when a
// snapshot disagrees.
type predictor struct {
	controller *game.CharacterController
	weapons    game.WeaponSet
	// match is the match seed, which the spread of shots comes from.
	match    uint64
	ticks    [predictionHistory]predictedTick
	soldier  game.Soldier
	previous physics.Vec3
	offset   physics.Vec3
	started  bool
	last     game.Tick

	// corrections counts the corrections, weaponCorrections those of them
	// where only the weapons disagreed.
	corrections       int
	weaponCorrections int
	lastError         float32
}

func newPredictor(world *physics.World, rules game.Rules) (*predictor, error) {
	tuning := rules.Movement
	// The client never pushes props: they are its own decoration, and every
	// replay would push them once more.
	tuning.PushStrength = 0
	controller, err := game.NewCharacterController(world, tuning, physics.Vec3{})
	if err != nil {
		return nil, err
	}
	return &predictor{controller: controller, weapons: rules.Weapons}, nil
}

// join starts a new session with the match seed it got: the next confirmed
// state starts the prediction again. The ticks of the last session are
// forgotten: the new one may reuse their numbers, and the server never saw
// their commands.
func (p *predictor) join(match uint64) {
	p.started, p.offset, p.match = false, physics.Vec3{}, match
	for i := range p.ticks {
		p.ticks[i] = predictedTick{state: p.ticks[i].state}
	}
}

func (p *predictor) close() error {
	return p.controller.Close()
}

// predict records the command of a tick and, once the soldier exists, applies
// it. Ticks skipped by a clock jump get the repeated command the server uses.
// It returns what the weapons did at the tick of the command, for the effects.
func (p *predictor) predict(command game.InputCommand) (game.WeaponStep, error) {
	if p.started && command.Tick <= p.last {
		// The clock jumped back; start again from the next confirmed state.
		p.started = false
	}
	if p.started {
		previous := p.ticks[p.last%predictionHistory].command
		for tick := p.last + 1; tick != command.Tick && command.Tick-tick < predictionHistory; tick++ {
			p.previous = p.soldier.Position
			if _, err := p.record(previous.Repeated(tick), true); err != nil {
				return game.WeaponStep{}, err
			}
		}
		p.previous = p.soldier.Position
	}
	return p.record(command, p.started)
}

func (p *predictor) record(command game.InputCommand, step bool) (game.WeaponStep, error) {
	slot := &p.ticks[command.Tick%predictionHistory]
	state := slot.state
	*slot = predictedTick{tick: command.Tick, command: command, state: state}
	p.last = command.Tick
	if !step {
		return game.WeaponStep{}, nil
	}
	return p.step(slot)
}

func (p *predictor) step(slot *predictedTick) (game.WeaponStep, error) {
	step, err := game.RunCommand(p.controller, &p.weapons, &p.soldier, slot.command, p.match)
	if err != nil {
		return step, err
	}
	slot.soldier, slot.stepped = p.soldier, true
	return step, p.controller.SaveState(&slot.state)
}

// reconcile compares the server's state of a tick with the prediction for that
// tick. On a mismatch it restores the server's state and replays the newer
// commands; the drawn soldier keeps its place and catches up smoothly.
func (p *predictor) reconcile(server protocol.PlayerState) error {
	if !server.Processed || server.Soldier == 0 {
		return nil
	}
	tick := server.LastProcessedTick
	slot := &p.ticks[tick%predictionHistory]
	known := p.started && slot.tick == tick && slot.stepped
	moved := !known || !near(slot.soldier.Position, server.Position, acceptedPositionError) ||
		!near(slot.soldier.Velocity, server.Velocity, acceptedVelocityError)
	if !moved && slot.soldier.Arsenal.Agrees(&server.Arsenal) {
		return nil
	}
	before := p.soldier.Position
	confirmed := game.Soldier{
		ID: server.Soldier, Alive: true, Position: server.Position, Velocity: server.Velocity, Arsenal: server.Arsenal,
	}
	var err error
	if known && distance(slot.soldier.Position, server.Position) < teleportDistance {
		err = p.controller.Restore(&confirmed, &slot.state)
	} else {
		err = p.controller.Place(&confirmed)
	}
	if err != nil {
		return err
	}
	if known {
		p.corrections++
		p.lastError = distance(slot.soldier.Position, server.Position)
		if !moved {
			p.weaponCorrections++
		}
	}
	p.soldier = confirmed
	previous := game.InputCommand{}
	if slot.tick == tick {
		previous = slot.command
	}
	if int32(tick-p.last) > 0 {
		// The server is ahead of the newest recorded tick.
		p.last = tick
	}
	for replay := tick + 1; replay-tick <= p.last-tick; replay++ {
		next := &p.ticks[replay%predictionHistory]
		if next.tick != replay {
			state := next.state
			*next = predictedTick{tick: replay, command: previous.Repeated(replay), state: state}
		}
		if _, err := p.step(next); err != nil {
			return err
		}
		previous = next.command
	}
	shift := p.soldier.Position.Sub(before)
	if !p.started || distance(before, p.soldier.Position) > teleportDistance {
		p.offset, p.previous = physics.Vec3{}, p.soldier.Position
	} else {
		p.previous, p.offset = p.previous.Add(shift), p.offset.Sub(shift)
	}
	p.started = true
	return nil
}

// drawn is where to show the soldier between two ticks: alpha is the share of
// the next tick already elapsed. It includes what is left of a correction.
func (p *predictor) drawn(alpha float32) physics.Vec3 {
	return p.previous.Add(p.soldier.Position.Sub(p.previous).Mul(alpha)).Add(p.offset)
}

func (p *predictor) smooth(deltaTime float32) {
	p.offset = p.offset.Mul(float32(math.Exp(-float64(deltaTime) / smoothingTime)))
}

func near(first, second physics.Vec3, limit float32) bool {
	d := first.Sub(second)
	return abs(d.X) <= limit && abs(d.Y) <= limit && abs(d.Z) <= limit
}

func distance(first, second physics.Vec3) float32 {
	d := first.Sub(second)
	return float32(math.Sqrt(float64(d.X*d.X + d.Y*d.Y + d.Z*d.Z)))
}

func abs(value float32) float32 {
	return float32(math.Abs(float64(value)))
}
