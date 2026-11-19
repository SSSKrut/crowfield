package animation

import (
	"fmt"
	"math"
	"os"
	"testing"
	"unsafe"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const robotPath = "../../assets/prototype/RobotExpressive.glb"

// robot is the model loaded by TestMain when a display is available: raylib
// needs a window, made on the main thread. Tests only read it and compute on
// the CPU.
var robot *CharacterAsset

func TestMain(m *testing.M) {
	if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
		os.Exit(m.Run())
	}
	rl.SetTraceLogLevel(rl.LogError)
	rl.SetConfigFlags(rl.FlagWindowHidden)
	rl.InitWindow(64, 64, "animation test")
	asset, err := LoadCharacterAsset(robotPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	robot = asset
	code := m.Run()
	robot.Close()
	rl.CloseWindow()
	os.Exit(code)
}

func needRobot(t *testing.T) *CharacterAsset {
	t.Helper()
	if robot == nil {
		t.Skip("needs a display to load the model")
	}
	return robot
}

// raylib loads 19 meshes from the robot: the hands are skinned, and their
// node is scaled by 100; the other parts hang under bones.
func TestGLTFMeshesDescribeTheRobot(t *testing.T) {
	meshes, err := gltfMeshes(robotPath)
	if err != nil {
		t.Fatal(err)
	}
	skinned, attached := 0, 0
	for _, mesh := range meshes {
		switch {
		case mesh.skinned:
			skinned++
			if scale := rl.Vector3Length(rl.Vector3Transform(rl.NewVector3(1, 0, 0), mesh.world)) - rl.Vector3Length(rl.Vector3Transform(rl.Vector3{}, mesh.world)); scale < 50 {
				t.Errorf("a hand node scales by %.1f, the file says 100", scale)
			}
		case mesh.hasParent:
			attached++
		}
	}
	if len(meshes) != 19 || skinned != 4 || attached != 15 {
		t.Errorf("%d meshes, %d skinned and %d under bones; want 19, 4 and 15", len(meshes), skinned, attached)
	}
}

func TestNodeTransformsComposeLikeGLTF(t *testing.T) {
	quarter := float32(math.Sqrt2 / 2)
	nodes := []gltfNode{
		{Children: []int{1}, Translation: &[3]float32{10, 0, 0}, Scale: &[3]float32{2, 2, 2}},
		// A quarter turn about Y takes +X to -Z.
		{Rotation: &[4]float32{0, quarter, 0, quarter}, Translation: &[3]float32{0, 1, 0}},
		{Matrix: []float32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 6, 7, 1}},
	}
	parents := []int{-1, 0, -1}
	point := rl.Vector3Transform(rl.NewVector3(1, 0, 0), nodeWorld(nodes, parents, 1))
	// Rotated to (0, 0, -1), moved up by 1, scaled by 2, moved by 10 in X.
	if rl.Vector3Distance(point, rl.NewVector3(10, 2, -2)) > 1e-5 {
		t.Errorf("child point lands at %+v", point)
	}
	if moved := rl.Vector3Transform(rl.Vector3{}, nodeWorld(nodes, parents, 2)); moved != rl.NewVector3(5, 6, 7) {
		t.Errorf("a column-major matrix translates to %+v", moved)
	}
}

// The robot assembled from its parts is as tall as the soldier capsule, with
// the feet on the ground, and no part strays from the body. raylib alone drew
// the hands a hundred times too large, far away. The robot is chunky: its head
// alone is 1.2 m wide.
func TestRobotStandsAsTallAsTheSoldier(t *testing.T) {
	bounds := needRobot(t).Bounds()
	size := rl.Vector3Subtract(bounds.Max, bounds.Min)
	if math.Abs(float64(bounds.Min.Y)) > 1e-4 || math.Abs(float64(size.Y-characterModelHeight)) > 1e-4 {
		t.Errorf("the robot spans %.3f..%.3f m in height", bounds.Min.Y, bounds.Max.Y)
	}
	if size.X > 2 || size.Z > 1.6 {
		t.Errorf("the robot is %.2f m wide and %.2f m deep", size.X, size.Z)
	}
	t.Logf("bounds %+v .. %+v", bounds.Min, bounds.Max)
}

// A precomputed keyframe is the exact pose at that frame.
func TestCachedPosesAreTheExactPoses(t *testing.T) {
	asset := needRobot(t)
	character := asset.NewCharacter()
	for _, clip := range []Clip{ClipIdle, ClipWalking, ClipRunning} {
		for _, frame := range []int{0, 7, asset.clips[clip].frames - 1} {
			character.clip, character.time, character.blend = clip, float32(frame)/keyframeRate, 1
			character.pose()
			cached := unsafe.Slice(asset.cachedPose(clip, character.time), int(asset.model.Skeleton.BoneCount))
			for bone, exact := range asset.model.GetBoneMatrices() {
				if !nearMatrix(exact, cached[bone]) {
					t.Fatalf("%s frame %d bone %d: cached %+v, exact %+v", clip, frame, bone, cached[bone], exact)
				}
			}
		}
	}
}

// A change of clip fades in over blendTime; walking and running keep the
// phase of the gait, so the feet do not jump.
func TestClipsChangeWithSpeedAndKeepTheGait(t *testing.T) {
	asset := needRobot(t)
	character := asset.NewCharacter()
	step := float32(1.0 / 60)
	for range 20 {
		_ = character.Update(step, 3)
	}
	if character.Clip() != ClipWalking || character.blend != 1 {
		t.Fatalf("walking: clip %s, blend %.2f", character.Clip(), character.blend)
	}
	phase := character.time / asset.period(ClipWalking)
	_ = character.Update(step, 8)
	if character.Clip() != ClipRunning || character.from != ClipWalking || character.blend > 0.1 {
		t.Fatalf("after speeding up: clip %s from %s, blend %.2f", character.Clip(), character.from, character.blend)
	}
	if got := character.time / asset.period(ClipRunning); math.Abs(float64(got-phase-step/asset.period(ClipRunning))) > 1e-4 {
		t.Errorf("the gait phase went from %.3f to %.3f", phase, got)
	}
	for range int(blendTime/step) + 1 {
		_ = character.Update(step, 8)
	}
	if character.blend != 1 {
		t.Errorf("blend %.2f after the blend time", character.blend)
	}
	_ = character.Update(step, 0)
	if character.Clip() != ClipIdle || character.time > step {
		t.Errorf("stopping: clip %s at %.3f s", character.Clip(), character.time)
	}
}

// A knocked down robot falls onto the ground, freezes once it rests, and keeps
// its pose without physics.
func TestRagdollFallsAndFreezes(t *testing.T) {
	asset := needRobot(t)
	if err := physics.Init(); err != nil {
		t.Fatal(err)
	}
	defer physics.Shutdown()
	world, err := physics.NewWorld()
	if err != nil {
		t.Fatal(err)
	}
	defer world.Close()
	if _, err := world.CreateBox(physics.BoxDesc{
		HalfExtents: physics.V(20, 0.25, 20),
		Transform:   physics.Transform{Position: physics.V(0, -0.25, 0), Rotation: physics.IdentityQuat()},
	}); err != nil {
		t.Fatal(err)
	}
	pool := asset.NewRagdollPool(world, 1)
	defer pool.Close()
	character := asset.NewCharacter()
	defer character.Close()
	strike := Strike{Part: RagdollHips, Point: physics.V(0, 0.55, 0), Impulse: physics.V(0, 5, 30)}
	if err := character.Fall(pool, physics.V(0, 0, 0), physics.IdentityQuat(), physics.Vec3{}, strike); err != nil {
		t.Fatal(err)
	}
	if !pool.Full() || fallAnyhow(pool, asset.NewCharacter()) == nil {
		t.Fatal("a pool of one lent a second ragdoll")
	}
	if !character.Fallen() || !character.RagdollActive() {
		t.Fatal("the character is not a ragdoll")
	}
	elapsed := float32(0)
	for character.RagdollActive() && elapsed < maxRagdollTime+1 {
		if err := world.Step(1.0 / 60); err != nil {
			t.Fatal(err)
		}
		if err := character.Update(1.0/60, 0); err != nil {
			t.Fatal(err)
		}
		elapsed += 1.0 / 60
	}
	if character.RagdollActive() || !character.Fallen() || character.matrices == nil {
		t.Fatalf("after %.1f s the ragdoll is still simulated or lost its pose", elapsed)
	}
	if hips := character.FallenAt(); hips.Y > 0.6 || hips.Z < 0.3 {
		t.Errorf("the body lies with its hips at %+v", hips)
	}
	frozen := append([]rl.Matrix(nil), character.matrices...)
	_ = character.Update(1, 0)
	for i := range frozen {
		if frozen[i] != character.matrices[i] {
			t.Fatal("a frozen pose changed")
		}
	}
	t.Logf("froze after %.2f s with the hips at %+v", elapsed, character.FallenAt())
	if pool.Lent() != 0 {
		t.Error("the frozen body kept its ragdoll")
	}
	// The next fall reuses the ragdoll: no bodies or joints are made.
	other := asset.NewCharacter()
	defer other.Close()
	if err := other.Fall(pool, physics.V(3, 0, 0), physics.IdentityQuat(), physics.Vec3{}, Strike{Part: -1}); err != nil {
		t.Fatal(err)
	}
	if pool.Made() != 1 || !other.RagdollActive() || math.Abs(float64(other.FallenAt().X-3)) > 0.3 {
		t.Errorf("the second fall: %d ragdolls made, active %t, hips at %+v", pool.Made(), other.RagdollActive(), other.FallenAt())
	}
	if err := character.RemoveRagdoll(); err != nil || character.Fallen() || character.matrices != nil {
		t.Errorf("standing up again: %v", err)
	}
}

// fallAnyhow drops a character at the origin without a strike.
func fallAnyhow(pool *RagdollPool, character *Character) error {
	return character.Fall(pool, physics.Vec3{}, physics.IdentityQuat(), physics.Vec3{}, Strike{Part: -1})
}

func TestWrapKeepsTimeInTheClip(t *testing.T) {
	for _, c := range []struct{ time, period, want float32 }{{0.5, 1, 0.5}, {1.25, 1, 0.25}, {3, 1.5, 0}} {
		if got := wrap(c.time, c.period); math.Abs(float64(got-c.want)) > 1e-6 {
			t.Errorf("wrap(%v, %v) = %v", c.time, c.period, got)
		}
	}
}

func nearMatrix(first, second rl.Matrix) bool {
	a, b := rl.MatrixToFloat(first), rl.MatrixToFloat(second)
	for i := range a {
		if math.Abs(float64(a[i]-b[i])) > 1e-4 {
			return false
		}
	}
	return true
}

// A hit on the head bends the neck so the head moves along the shot; a hit
// on a hand swings the arm along the shot too. The spring stays within its
// limit and settles within a second.
func TestFlinchMovesTheStruckPartAlongTheShot(t *testing.T) {
	asset := needRobot(t)
	for _, c := range []struct {
		part int
		bone string
	}{{RagdollHead, "Head"}, {RagdollLowerArmRight, "Palm2.R"}, {RagdollTorso, "Neck"}} {
		character := asset.NewCharacter()
		shot := physics.V(0.6, 0, 0.8)
		character.Flinch(c.part, shot, physics.IdentityQuat())
		if err := character.Update(0.06, 0); err != nil {
			t.Fatal(err)
		}
		character.pose()
		character.applyFlinch()
		bone := asset.bones[c.bone]
		rest := asset.model.GetCurrentPose()[bone].Translation
		moved := rl.Vector3Subtract(rl.Vector3Transform(rest, asset.deltas[bone]), rest)
		along := moved.X*shot.X + moved.Z*shot.Z
		if along <= 0 || character.flinch.angle > maxFlinch {
			t.Errorf("%s moved %+v, %.3f along the shot; angle %.3f", c.bone, moved, along, character.flinch.angle)
		}
		for range 60 {
			_ = character.Update(1.0/60, 0)
		}
		if character.Flinching() {
			t.Errorf("a hit on part %d still flinches after a second: %.4f", c.part, character.flinch.angle)
		}
		_ = character.Close()
	}
}

// A strike as hard as the client gives on any part knocks the body over
// where it stood: a light part struck does not fling it across the map. A
// soldier that falls on the run slides on, toppled 1.8 m tall: its hips end
// up two or three metres on.
func TestStrikesKnockDownWithoutFlinging(t *testing.T) {
	asset := needRobot(t)
	if err := physics.Init(); err != nil {
		t.Fatal(err)
	}
	defer physics.Shutdown()
	world, err := physics.NewWorld()
	if err != nil {
		t.Fatal(err)
	}
	defer world.Close()
	if _, err := world.CreateBox(physics.BoxDesc{
		HalfExtents: physics.V(20, 0.25, 20),
		Transform:   physics.Transform{Position: physics.V(0, -0.25, 0), Rotation: physics.IdentityQuat()},
	}); err != nil {
		t.Fatal(err)
	}
	pool := asset.NewRagdollPool(world, ragdollParts)
	defer pool.Close()
	characters := make([]*Character, ragdollParts)
	for part := range ragdollParts {
		characters[part] = asset.NewCharacter()
		defer characters[part].Close()
		root := physics.V(float32(part)*3-18, 0, 0)
		blow := Strike{Part: part, Point: root.Add(physics.V(0, 0.9, 0)), Impulse: physics.V(0, 5, 30)}
		if err := characters[part].Fall(pool, root, physics.IdentityQuat(), physics.V(0, 0, 5), blow); err != nil {
			t.Fatal(err)
		}
	}
	for range 8 * 60 {
		if err := world.Step(1.0 / 60); err != nil {
			t.Fatal(err)
		}
		for _, character := range characters {
			if err := character.Update(1.0/60, 0); err != nil {
				t.Fatal(err)
			}
		}
	}
	for part, character := range characters {
		root := physics.V(float32(part)*3-18, 0, 0)
		hips := character.FallenAt()
		if moved := vectorLength(hips.Sub(root)); moved > 3.5 || hips.Y < 0 || character.RagdollActive() {
			t.Errorf("struck on part %d, the body lies %.2f m away at %+v, active %t", part, moved, hips, character.RagdollActive())
		}
	}
}
