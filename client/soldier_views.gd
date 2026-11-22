class_name SoldierViews
extends Node3D
## SoldierViews draws every other soldier with the shared character asset.
## Each has its own animation state, made when the soldier is first seen and
## dropped when it is gone. A soldier that dies falls as a ragdoll into the
## bodies of the world. Their shots and hits show when the interpolation
## reaches them.

## The FULL_DETAIL soldiers nearest to the camera within FULL_DETAIL_DISTANCE
## animate every frame; the rest every few frames.
const FULL_DETAIL := 8
const FULL_DETAIL_DISTANCE := 20.0
const COARSE_FRAMES := 3
## Beyond FAR_DISTANCE a soldier that dies is simply gone.
const FAR_DISTANCE := 150.0
## KNOCK_DOWN is how many of the nearest soldiers the debug key knocks down.
const KNOCK_DOWN := 16
## Soldiers farther than FLINCH_DISTANCE do not flinch: it would not show.
const FLINCH_DISTANCE := 80.0
## The bullet that kills strikes its part with STRIKE_IMPULSE N·s along its
## flight, and a little up.
const STRIKE_IMPULSE := 30.0
const STRIKE_LIFT := 5.0
## A blast throws the soldiers it kills: one at its heart with BLAST_IMPULSE
## N·s away from it and BLAST_LIFT up, less the farther, if it died within
## BLAST_TICKS of it. A blast is remembered BLAST_MEMORY ticks.
const BLAST_IMPULSE := 260.0
const BLAST_LIFT := 160.0
const BLAST_TICKS := 8.0
const BLAST_MEMORY := 2 * Game.TICK_RATE
## A soldier shot dead loses its stride: its body keeps FALL_MOMENTUM of its
## speed along the ground, and all of it up and down. With all of it, a bot
## that ran at 5 m/s slid two metres on after it fell.
const FALL_MOMENTUM := 0.3
## Shots further behind than STALE_SHOTS ticks are not shown: the soldier was
## not drawn for a while.
const STALE_SHOTS := Game.TICK_RATE / 2
## HITBOX_PARTS are the ragdoll parts the hitboxes cover (Hitboxes): a hitbox
## on the soldier's left is a part on the model's left.
const HITBOX_PARTS := [
	RagdollRig.Part.HEAD, RagdollRig.Part.TORSO, RagdollRig.Part.LOWER_LEG_LEFT, RagdollRig.Part.LOWER_LEG_RIGHT,
	RagdollRig.Part.UPPER_ARM_LEFT, RagdollRig.Part.UPPER_ARM_RIGHT, RagdollRig.Part.LOWER_ARM_LEFT, RagdollRig.Part.LOWER_ARM_RIGHT,
]
const TEAM_COLORS := {Game.Team.BLUE: Color8(60, 110, 220), Game.Team.RED: Color8(210, 70, 60)}

var asset: CharacterAsset
var pool: RagdollPool
var bodies: Bodies
var view_model: ViewModel
var effects: Effects
var sounds: Sounds
var rules: Rules
## What the last frame showed, for the overlay and the log, and how many
## soldiers fell so far.
var drawn := 0
var full := 0
var falls := 0
## aimed is the soldier nearest to the crosshair, if any.
var aimed: KnownSoldier
## shown are the soldiers drawn this frame.
var shown: Array[Entry] = []
var _entries := {}
var _frame := 0
var _ray := PhysicsRayQueryParameters3D.new()
## _blasts are the recent blasts as [where, radius, tick].
var _blasts: Array = []
var _render_tick := 0.0


func tint(team: int) -> Color:
	return TEAM_COLORS.get(team, asset.accent)


## update places every other soldier at the interpolation time, advances its
## animation and shows its combat. A soldier that is dead at that time falls.
func update(session: ClientSession, delta: float, camera: Camera3D, scene: MapScene) -> void:
	_frame += 1
	_render_tick = session.clock.render_tick
	var eye := camera.global_position
	for id in _entries.keys():
		var known: KnownSoldier = session.soldiers.get(SoldierSet.slot_of(id))
		if known == null or known.soldier.id != id:
			_drop(id)
	shown.clear()
	for known: KnownSoldier in session.soldiers.values():
		var id := known.soldier.id
		if id == session.player.soldier or known.remote.count == 0:
			continue
		var remote := known.remote
		remote.smooth(delta)
		remote.evaluate(session.clock.render_tick)
		var entry: Entry = _entries.get(id)
		if not remote.alive:
			_show_combat(known, entry, session.clock.render_tick)
			if entry != null:
				_entries.erase(id)
				_fall(entry, known, eye)
			continue
		if entry == null:
			entry = Entry.new()
			entry.view = asset.instantiate()
			entry.view.set_tint(tint(known.soldier.team))
			add_child(entry.view)
			_entries[id] = entry
		entry.known = known
		entry.distance = remote.position.distance_to(eye)
		entry.view.face(remote.position, remote.yaw)
		var speed := Game.horizontal_length(remote.velocity)
		entry.view.animate(delta, speed, remote.crouched)
		if sounds != null:
			var near_enough := entry.distance < Sounds.REMOTE_FOOTSTEP_RANGE
			if entry.footstep_due(remote, speed / rules.movement.sprint_speed, delta, near_enough):
				sounds.footstep_at(remote.position, scene, entry.distance)
		shown.append(entry)
	drawn = shown.size()
	full = 0
	# The nearest few within reach animate every frame: a threshold from the
	# distances, without sorting them all.
	var near := PackedFloat32Array()
	for entry in shown:
		if entry.distance <= FULL_DETAIL_DISTANCE:
			near.append(entry.distance)
	var threshold := FULL_DETAIL_DISTANCE
	if near.size() > FULL_DETAIL:
		near.sort()
		threshold = near[FULL_DETAIL - 1]
	for entry in shown:
		var detailed := entry.distance <= threshold and full < FULL_DETAIL
		entry.view.set_detail(detailed)
		entry.view.set_foot_terrain(scene.terrain if detailed and entry.known.remote.grounded else null)
		if detailed:
			full += 1
		else:
			entry.coarse += delta
			if (_frame + entry.known.soldier.id) % COARSE_FRAMES == 0:
				entry.view.player.advance(entry.coarse)
				entry.coarse = 0.0
		var known := entry.known
		var remote := known.remote
		_hold(entry, known.soldier.arsenal.weapon(), remote, known.soldier.team)
		var hit := _show_combat(known, entry, session.clock.render_tick)
		if hit and entry.distance < FLINCH_DISTANCE:
			entry.view.hit(HITBOX_PARTS[mini(known.soldier.hit_box, Hitboxes.COUNT - 1)], Game.view_direction(known.soldier.hit_yaw, 0))


## _hold puts the weapon the soldier carries in its hands.
func _hold(entry: Entry, kind: int, remote: RemoteSoldier, team: int) -> void:
	if view_model == null:
		return
	if entry.held_kind != kind:
		if entry.held != null:
			entry.held.queue_free()
		entry.held = view_model.make_held(kind, tint(team))
		entry.held_kind = kind
		if entry.held != null:
			add_child(entry.held)
	var carried := entry.view.carry(view_model, kind, remote.pitch)
	if entry.held != null:
		entry.held.transform = carried


func _drop(id: int) -> void:
	var entry: Entry = _entries[id]
	_entries.erase(id)
	if entry.held != null:
		entry.held.queue_free()
	entry.view.queue_free()


## _show_combat shows the shots a soldier fired and the hit it took once the
## interpolation reaches them: a flash at the muzzle of its weapon, a tracer to
## where its aim meets the world, the sound, and sparks off the hitbox that was
## struck. It reports a hit shown.
func _show_combat(known: KnownSoldier, entry: Entry, render_tick: float) -> bool:
	if effects == null:
		known.shots.clear()
		known.hurt = false
		return false
	var remote := known.remote
	var shown_shots := 0
	var kind := known.soldier.arsenal.weapon()
	var fired := false
	while shown_shots < known.shots.size() and known.shots[shown_shots] <= render_tick:
		if known.shots[shown_shots] >= render_tick - STALE_SHOTS:
			var carried := ViewModel.held_transform(remote.position, remote.yaw, remote.pitch)
			if entry != null and entry.held != null:
				if remote.alive and not fired:
					entry.view.fired()
					entry.held.transform = entry.view.carry(view_model, kind, remote.pitch)
					fired = true
				carried = entry.held.transform
			_show_shot(kind, remote, carried)
		shown_shots += 1
	if shown_shots > 0:
		known.shots = known.shots.slice(shown_shots)
	if not known.hurt or known.hit > render_tick:
		return false
	known.hurt = false
	var box := mini(known.soldier.hit_box, Hitboxes.COUNT - 1)
	effects.hit(Hitboxes.center(box, remote.position, remote.yaw, remote.crouched), Game.view_direction(known.soldier.hit_yaw, 0))
	return true


## _show_shot shows one shot of another soldier. Its spread is the server's
## secret; a little scatter keeps a burst from drawing one line, and the
## pellets of a shotgun fly within their cone.
func _show_shot(kind: int, remote: RemoteSoldier, carried: Transform3D) -> void:
	var tuning := rules.weapons.get_tuning(kind)
	if tuning == null or view_model == null:
		return
	var muzzle := view_model.held_muzzle(kind, carried)
	if muzzle == Vector3.INF:
		return
	const SCATTER := 0.012
	var eye := remote.position + Vector3.UP * rules.movement.view_height(remote.crouched)
	var spread := SCATTER + deg_to_rad(tuning.pellet_spread)
	var struck := Vector3.INF
	for pellet in tuning.pellets:
		var direction := Game.view_direction(remote.yaw + spread * (effects.random.randf() * 2 - 1),
			remote.pitch + spread * (effects.random.randf() * 2 - 1))
		var end := eye + direction * tuning.range
		_ray.from = eye
		_ray.to = end
		_ray.collision_mask = Game.LAYER_STATIC | Game.LAYER_VEHICLE
		var hit := get_world_3d().direct_space_state.intersect_ray(_ray)
		if not hit.is_empty():
			end = hit["position"]
			struck = end
		effects.shot(muzzle, end, not hit.is_empty(), hit.get("normal", Vector3.ZERO))
	effects.flash(muzzle)
	if sounds != null:
		sounds.shot_at(kind, muzzle)
		# One sound for the pellets of a shotgun that struck.
		if struck != Vector3.INF:
			sounds.impact_at(struck)


## momentum is the velocity a soldier that dies at velocity falls with.
static func momentum(velocity: Vector3) -> Vector3:
	return Vector3(velocity.x * FALL_MOMENTUM, velocity.y, velocity.z * FALL_MOMENTUM)


## remember_blast keeps a blast that showed, for the soldiers it kills.
func remember_blast(at: Vector3, radius: float, tick: float) -> void:
	_blasts = _blasts.filter(func(blast: Array) -> bool: return tick - blast[2] < BLAST_MEMORY)
	_blasts.append([at, radius, tick])


## blow is the blow that fells a soldier at its death at a tick: the throw
## of a blast that burst by it just then, or the strike of the last hit.
func blow(soldier_position: Vector3, yaw: float, hit_box: int, hit_yaw: float, tick: float, crouched := false) -> CharacterView.Strike:
	# The middle of the body, where the server measures a blast to.
	var center := soldier_position + Vector3(0, 0.45 if crouched else 0.85, 0)
	for blast: Array in _blasts:
		var away: Vector3 = center - blast[0]
		var distance := away.length()
		var radius: float = blast[1]
		if distance > radius or absf(tick - blast[2]) > BLAST_TICKS:
			continue
		var share := 1.0 - distance / radius
		var outward := away / distance if distance > 0.01 else Vector3.UP
		var impulse := outward * BLAST_IMPULSE * share + Vector3.UP * BLAST_LIFT * share
		return CharacterView.Strike.new(RagdollRig.Part.HIPS, center, impulse)
	return strike(soldier_position, yaw, hit_box, hit_yaw, crouched)


## strike is the blow of the last hit on a soldier, for its fall.
static func strike(soldier_position: Vector3, yaw: float, hit_box: int, hit_yaw: float, crouched := false) -> CharacterView.Strike:
	var box := mini(hit_box, Hitboxes.COUNT - 1)
	var impulse := Game.view_direction(hit_yaw, 0) * STRIKE_IMPULSE + Vector3(0, STRIKE_LIFT, 0)
	return CharacterView.Strike.new(HITBOX_PARTS[box], Hitboxes.center(box, soldier_position, yaw, crouched), impulse)


## _fall turns a soldier that died into a ragdoll from its pose, struck where
## the bullet that killed it hit. Far away it is simply gone.
func _fall(entry: Entry, known: KnownSoldier, eye: Vector3) -> void:
	if entry.held != null:
		entry.held.queue_free()
	var remote := known.remote
	if pool == null or remote.position.distance_to(eye) > FAR_DISTANCE:
		entry.view.queue_free()
		return
	bodies.make_room(pool, eye)
	var fell := blow(remote.position, remote.yaw, known.soldier.hit_box, known.soldier.hit_yaw, _render_tick, remote.crouched)
	if not entry.view.fall(pool, momentum(remote.last_alive_velocity()), fell):
		entry.view.queue_free()
		return
	falls += 1
	bodies.add(entry.view)
	remove_child(entry.view)
	bodies_parent.add_child(entry.view)


## bodies_parent holds the fallen, which outlive the soldiers.
var bodies_parent: Node3D


## aim finds the soldier nearest to the line of sight, within a few degrees,
## as the server does for its priorities: from the soldier's eye along the
## command's direction, whatever the camera, to the middle of the body.
func aim(eye: Vector3, forward: Vector3) -> void:
	const LIMIT := 3.0 * PI / 180.0
	aimed = null
	var best := LIMIT
	for entry in shown:
		var remote := entry.known.remote
		var to := remote.position + Vector3.UP * rules.movement.center_height(remote.crouched) - eye
		var length := to.length()
		if length < 1e-3:
			continue
		var angle := acos(clampf(forward.dot(to) / length, -1, 1)) - atan(0.5 / length)
		if angle < best:
			aimed = entry.known
			best = angle


## knock_down drops ragdoll copies of the nearest soldiers in view, struck in
## the body away from the eye. The soldiers walk on: the server knows nothing
## of it. It loads the ragdolls.
func knock_down(eye: Vector3) -> void:
	var nearest := shown.duplicate()
	nearest.sort_custom(func(a: Entry, b: Entry) -> bool: return a.distance < b.distance)
	for i in mini(KNOCK_DOWN, nearest.size()):
		var entry: Entry = nearest[i]
		var remote := entry.known.remote
		var away := remote.position - eye
		away.y = 0
		var length := maxf(away.length(), 1e-3)
		var blow := CharacterView.Strike.new(RagdollRig.Part.TORSO, remote.position + Vector3(0, 0.85, 0),
			away * (STRIKE_IMPULSE / length) + Vector3(0, STRIKE_LIFT, 0))
		bodies.make_room(pool, eye)
		var copy := asset.instantiate()
		copy.set_tint(tint(entry.known.soldier.team))
		bodies_parent.add_child(copy)
		copy.transform = entry.view.transform
		copy.copy_pose(entry.view)
		if copy.fall(pool, remote.velocity, blow):
			bodies.add(copy)
		else:
			copy.queue_free()


## Entry is a soldier drawn this frame.
class Entry:
	var view: CharacterView
	var known: KnownSoldier
	var held: Node3D
	var held_kind := -1
	var distance := 0.0
	## coarse is the animation time owed to a soldier animated every few frames.
	var coarse := 0.0
	var foot_position := Vector3.INF
	var foot_travel := 0.0


	## Advance the gait from drawn motion. A new, airborne, or corrected
	## soldier needs a clean sample before it can make another step.
	func footstep_due(remote: RemoteSoldier, speed_ratio: float, delta: float, nearby: bool) -> bool:
		if not nearby or not remote.grounded:
			foot_position = Vector3.INF
			foot_travel = 0.0
			return false
		var offset := remote.position - foot_position
		foot_position = remote.position
		var max_travel := maxf(0.9, delta * 12.0)
		if not offset.is_finite() or offset.length_squared() > max_travel * max_travel:
			foot_travel = 0.0
			return false
		if speed_ratio < 0.04:
			return false
		var stride_length := lerpf(0.80, 2.0, clampf(speed_ratio, 0.0, 1.0))
		foot_travel += Vector2(offset.x, offset.z).length()
		if foot_travel < stride_length:
			return false
		foot_travel = fposmod(foot_travel, stride_length)
		return true
