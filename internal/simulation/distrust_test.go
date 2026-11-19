package simulation

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
)

// The server trusts no client (specification, 9.8): a client sends only
// commands, and these tests forge the worst commands the protocol carries.
// Damage, hits, ammo and positions are the server's alone.

// forge queues a command for the shooter's coming tick, as any client may.
func (r *rangeTest) forge(command game.InputCommand) {
	command.Tick = r.server.tick
	r.shooter.inputs.put(command, r.server.tick)
	r.idle(1)
}

func (r *rangeTest) shots() uint64 {
	return r.server.profile.shots
}

// Pulling the trigger every other tick fires no faster than the weapon
// allows: the rifle about three rounds a second, however fast the clicks.
func TestForgedClicksDoNotOutshootTheRate(t *testing.T) {
	r := newRangeTest(t, config.Server{})
	rifle := r.server.rules.Weapons.Rifle
	for range rifle.EquipTicks() + 1 {
		r.forge(game.InputCommand{Weapon: 1})
	}
	before := r.shots()
	const ticks = 2 * game.TickRate
	for tick := range ticks {
		command := game.InputCommand{Weapon: 1, Pitch: 8000}
		if tick%2 == 0 {
			command.Buttons = game.ButtonFire
		}
		r.forge(command)
	}
	if fired, most := r.shots()-before, uint64(ticks/rifle.FireInterval()+1); fired > most {
		t.Errorf("clicking every other tick fired %d rifle rounds in 2 s, at most %d may", fired, most)
	}
}

// Holding the trigger and pressing reload every tick makes no rounds: what
// was fired and what is left always add up to what the soldier spawned with,
// and it never fires faster than the weapon. Holding on fires every round,
// no more, and leaves the weapon empty.
func TestForgedReloadsDoNotMakeAmmo(t *testing.T) {
	r := newRangeTest(t, config.Server{})
	rifle := r.server.rules.Weapons.AssaultRifle
	all := uint64(rifle.Magazine + rifle.Reserve)
	soldier := r.server.soldiers.Get(r.shooter.soldier)
	before := r.shots()
	left := func() uint64 {
		return uint64(soldier.Arsenal.Ammo[0].Magazine) + uint64(soldier.Arsenal.Ammo[0].Reserve)
	}
	most := uint64(0)
	for range 10 {
		start := r.shots()
		for range game.TickRate {
			r.forge(game.InputCommand{Buttons: game.ButtonFire | game.ButtonReload, Pitch: 8000})
			if fired := r.shots() - before; fired+left() != all {
				t.Fatalf("%d fired and %d left of %d", fired, left(), all)
			}
		}
		most = max(most, r.shots()-start)
	}
	for range 30 * game.TickRate {
		r.forge(game.InputCommand{Buttons: game.ButtonFire, Pitch: 8000})
	}
	if limit := uint64(game.TickRate/rifle.FireInterval() + 1); most > limit {
		t.Errorf("fired %d rounds in a second, at most %d may", most, limit)
	}
	if fired := r.shots() - before; fired != all || left() != 0 {
		t.Errorf("fired %d rounds of %d, %d left", fired, all, left())
	}
}

// The largest axes the protocol carries, diagonally and sprinting, move a
// soldier no faster than a sprint; a weapon slot outside the loadout and a
// pitch past straight up change nothing.
func TestForgedAxesDoNotOutrunTheSprint(t *testing.T) {
	r := newRangeTest(t, config.Server{})
	soldier := r.server.soldiers.Get(r.shooter.soldier)
	fastest := float32(0)
	for range game.TickRate {
		r.forge(game.InputCommand{MoveForward: -128, MoveRight: 127, Pitch: math.MinInt16, Weapon: 15, Buttons: game.ButtonSprint})
		fastest = max(fastest, float32(math.Hypot(float64(soldier.Velocity.X), float64(soldier.Velocity.Z))))
	}
	if sprint := r.server.rules.Movement.SprintSpeed; fastest > sprint*1.0001 {
		t.Errorf("forged axes ran at %.2f m/s, the sprint is %.2f", fastest, sprint)
	}
	if soldier.Arsenal.Current != 0 || soldier.Pitch < -math.Pi/2 {
		t.Errorf("weapon slot %d, pitch %.3f", soldier.Arsenal.Current, soldier.Pitch)
	}
}

// A claimed moment of view is tested no later than the last recorded tick
// and no earlier than the rewind limit, whatever the command says.
func TestForgedViewTimeIsBounded(t *testing.T) {
	r := newRangeTest(t, config.Server{MaxRewind: 300 * time.Millisecond})
	s := r.server
	latest := float64(s.tick) - 1
	oldest := float64(s.tick) - 18
	for _, c := range []struct {
		delta, fraction uint8
		want            float64
	}{
		{0, 0, latest}, {1, 255, latest}, {5, 128, float64(s.tick) - 4.5}, {255, 255, oldest},
	} {
		view := s.viewTime(game.InputCommand{Tick: s.tick, ViewDelta: c.delta, ViewFrac: c.fraction})
		if math.Abs(view-c.want) > 1e-5 {
			t.Errorf("view %d ticks and %d/256 back is tested at %.3f, want %.3f", c.delta, c.fraction, view, c.want)
		}
	}
}

// A multiplayer server refuses the respawn request, which would heal and
// refill at will.
func TestRespawnIsRefusedOutsideSoloPlay(t *testing.T) {
	server, listener := startServer(t, config.Server{MaxPlayers: 2, SnapshotRate: game.TickRate})
	client := join(t, listener, "cheater")
	snapshot := client.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	tick := snapshot.ServerTick + 3
	for range 30 {
		snapshot = client.snapshot(t)
		for tick <= snapshot.ServerTick+3 {
			client.send(t, game.NewInputCommand(tick, 1, 0, 0, 0, game.ButtonSprint|game.ButtonFire))
			tick++
		}
	}
	sendMessage(t, client.conn, &protocol.Respawn{})
	for range 30 {
		snapshot = client.snapshot(t)
		for tick <= snapshot.ServerTick+3 {
			client.send(t, game.NewInputCommand(tick, 0, 0, 0, 0, 0))
			tick++
		}
	}
	spawn := server.scene.SpawnOf(game.TeamBlue)
	if offset := snapshot.Player.Position.Sub(spawn); math.Hypot(float64(offset.X), float64(offset.Z)) < 1 ||
		snapshot.Player.Arsenal.Ammo[0].Magazine == 30 {
		t.Errorf("the respawn was granted: at %+v with %+v", snapshot.Player.Position, snapshot.Player.Arsenal.Ammo[0])
	}
}

// A client that floods the server with input datagrams has most of them
// dropped unread, while another player's commands all run in time; one that
// floods it with reliable messages is disconnected.
func TestFloodsAreDropped(t *testing.T) {
	server, listener := startServer(t, config.Server{MaxPlayers: 3, SnapshotRate: game.TickRate})
	honest := join(t, listener, "honest")
	flooder := join(t, listener, "flooder")
	spammer := join(t, listener, "spammer")
	snapshot := honest.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	flood, err := (&protocol.InputPacket{Commands: []game.InputCommand{{Tick: snapshot.ServerTick + 5}}}).Encode(nil)
	if err != nil {
		t.Fatal(err)
	}
	tick := snapshot.ServerTick + 3
	late := 0
	for range 60 {
		for range 200 {
			_ = flooder.conn.SendUnreliable(flood)
		}
		snapshot = honest.snapshot(t)
		if snapshot.ServerTick > tick && snapshot.Player.InputLead < 0 {
			late++
		}
		for tick <= snapshot.ServerTick+3 {
			honest.send(t, game.NewInputCommand(tick, 1, 0, 0, 0, 0))
			tick++
		}
	}
	if late > 0 {
		t.Errorf("%d snapshots of the honest player report late commands", late)
	}
	if dropped := server.droppedInputs.Load(); dropped < 1000 {
		t.Errorf("only %d of 12000 flooding datagrams were dropped", dropped)
	}
	for range 4 * controlBurst {
		data, _ := (&protocol.Ready{}).Encode(nil)
		if err := spammer.conn.SendReliable(transport.ChannelControl, data); err != nil {
			break
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for {
		_, _, err := spammer.conn.ReceiveReliable(ctx)
		var closed *transport.CloseError
		if errors.As(err, &closed) {
			if closed.Reason != "too many messages" {
				t.Errorf("the spammer was closed for %q", closed.Reason)
			}
			break
		}
		if err != nil {
			t.Fatalf("the spammer stays connected: %v", err)
		}
	}
}

// A client cannot claim damage: events go from the server only, and one
// that sends the server a hit or a death of its own making is disconnected,
// while the soldier it names keeps its health.
func TestClaimedDamageIsRefused(t *testing.T) {
	_, listener := startServer(t, config.Server{MaxPlayers: 2, SnapshotRate: game.TickRate})
	victim := join(t, listener, "victim")
	liar := join(t, listener, "liar")
	snapshot := victim.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	target := snapshot.Player.Soldier
	liar.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	for _, claim := range []protocol.Message{
		&protocol.HitConfirm{Tick: snapshot.ServerTick, Victim: target, Zone: game.ZoneHead, Damage: 255, Killed: true},
		&protocol.Death{Tick: snapshot.ServerTick, Victim: target, Killer: target, VictimName: "victim", KillerName: "liar"},
	} {
		data, err := claim.Encode(nil)
		if err != nil {
			t.Fatal(err)
		}
		_ = liar.conn.SendReliable(transport.ChannelEvents, data)
		_ = liar.conn.SendReliable(transport.ChannelControl, data)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for {
		_, _, err := liar.conn.ReceiveReliable(ctx)
		var closed *transport.CloseError
		if errors.As(err, &closed) {
			break
		}
		if err != nil {
			t.Fatalf("the liar stays connected: %v", err)
		}
	}
	for range 10 {
		snapshot = victim.snapshot(t)
	}
	if snapshot.Player.Health != game.MaxHealth || snapshot.Player.Soldier != target {
		t.Errorf("after the claims the victim has health %d as soldier %#04x", snapshot.Player.Health, snapshot.Player.Soldier)
	}
}
