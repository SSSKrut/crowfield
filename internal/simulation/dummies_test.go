package simulation

import (
	"math"
	"testing"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

func TestDummiesRoamWithoutGettingStuck(t *testing.T) {
	server := newTestServer(t, config.Server{MaxPlayers: 1, SnapshotRate: 20, Dummies: 256})
	start := map[game.SoldierID]physics.Vec3{}
	for soldier := range server.soldiers.All() {
		start[soldier.ID] = soldier.Position
	}
	const seconds = 10
	for range seconds * game.TickRate {
		if err := server.step(); err != nil {
			t.Fatal(err)
		}
	}
	area := server.scene.PlayArea
	travelled, crowded := float32(0), 0
	for soldier := range server.soldiers.All() {
		p := soldier.Position
		if math.Abs(float64(p.X)) > float64(area) || math.Abs(float64(p.Z)) > float64(area) || p.Y < -0.01 || p.Y > 1.6 {
			t.Fatalf("dummy %#04x left the play area: %+v", soldier.ID, p)
		}
		hit, _ := server.world.RayCast(physics.Ray{
			Origin: p.Add(physics.V(0, 0.3, 0)), Direction: physics.V(0, -1, 0), Distance: 0.5,
		}, physics.Mask(physics.LayerStatic))
		if !hit.Hit || hit.Fraction == 0 {
			t.Fatalf("dummy %#04x is inside geometry or in the air at %+v", soldier.ID, p)
		}
		travelled += distance(p, start[soldier.ID])
		for _, other := range server.grid.Near(p, 0.3) {
			if other != p {
				crowded++
			}
		}
	}
	if average := travelled / 256; average < 3 {
		t.Errorf("dummies moved only %.1f m on average from where they started", average)
	}
	// Separation is soft, but dummies must not pile up.
	if crowded > 26 {
		t.Errorf("%d dummies stand within 30 cm of another", crowded/2)
	}
}

func TestPoseHistoryInterpolatesAndForgets(t *testing.T) {
	soldiers, err := game.NewSoldierSet(1)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := soldiers.Add(game.Soldier{Alive: true})
	history := newPoseHistory(1)
	for tick := game.Tick(100); tick < 100+2*historyTicks; tick++ {
		soldier := soldiers.Get(id)
		soldier.Position = physics.V(float32(tick), 0, 0)
		soldier.Yaw = float32(2*math.Pi) - 0.05 + float32(tick%2)*0.1
		history.record(tick, soldiers)
	}
	last := game.Tick(100 + 2*historyTicks - 1)
	pose, ok := history.at(id, float64(last)-10.25)
	if !ok || math.Abs(float64(pose.position.X)-(float64(last)-10.25)) > 1e-3 {
		t.Errorf("pose at %.2f: %+v %t", float64(last)-10.25, pose, ok)
	}
	if yaw := math.Remainder(float64(pose.yaw), 2*math.Pi); math.Abs(yaw) > 0.06 {
		t.Errorf("yaw went the long way round: %.3f", pose.yaw)
	}
	if _, ok := history.at(id, float64(last-historyTicks)); ok {
		t.Error("a tick older than the history was found")
	}
	if _, ok := history.at(id, float64(last)+0.5); ok {
		t.Error("a pose after the newest tick was made up")
	}
	soldiers.Remove(id)
	newcomer, _ := soldiers.Add(game.Soldier{})
	history.record(last+1, soldiers)
	if _, ok := history.at(id, float64(last)+1); ok {
		t.Error("the slot's new soldier answered for the old one")
	}
	if _, ok := history.at(newcomer, float64(last)+1); !ok {
		t.Error("the new soldier was not recorded")
	}
}

// BenchmarkTick measures a whole tick with 256 dummies and 16 players that
// receive snapshots: one tick in three sends them.
func BenchmarkTick(b *testing.B) {
	server := newTestServer(b, config.Server{MaxPlayers: 16, SnapshotRate: 20, Dummies: 256})
	for id := range 16 {
		conn, peer := transport.NewMemoryPair()
		b.Cleanup(func() { _ = conn.Close("done"); _ = peer.Close("done") })
		p := server.newPlayer(game.PlayerID(id), "bench", conn)
		p.ready = true
		if err := server.spawn(p); err != nil {
			b.Fatal(err)
		}
		server.players[id] = p
	}
	for range game.TickRate {
		if err := server.step(); err != nil {
			b.Fatal(err)
		}
	}
	b.ResetTimer()
	for b.Loop() {
		if err := server.step(); err != nil {
			b.Fatal(err)
		}
	}
}

func newTestServer(t testing.TB, settings config.Server) *Server {
	t.Helper()
	server, err := NewServer(settings, game.DefaultMovementTuning())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	return server
}

func distance(first, second physics.Vec3) float32 {
	d := first.Sub(second)
	return float32(math.Sqrt(float64(d.X*d.X + d.Y*d.Y + d.Z*d.Z)))
}
