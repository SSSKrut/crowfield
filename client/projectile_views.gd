class_name ProjectileViews
extends Node3D
## ProjectileViews draws the rockets and grenades in flight and bursts them. A
## projectile flies by the code of the server (Projectile) through the
## client's copy of the static world, from the tick it left, at the time the
## player sees: the interpolation time for those of other soldiers, and the
## predicted present for the player's own, which leaves at once, before the
## server knows of it. It bursts where the server says, when that time
## reaches the tick of the blast.

## blasted tells of a blast as it shows, for the falls it throws and the
## shake of the camera.
signal blasted(at: Vector3, radius: float, tick: float)

## An own projectile the server does not confirm in ORPHAN_TICKS is dropped,
## and so is a projectile whose blast does not come LOST_TICKS after it
## should have burst.
const ORPHAN_TICKS := 2 * Game.TICK_RATE
const LOST_TICKS := 5 * Game.TICK_RATE
## A rocket leaves a puff of smoke every TRAIL_SPACING metres.
const TRAIL_SPACING := 0.3
const TRAIL_START := 3.0

var rules: Rules
var effects: Effects
var sounds: Sounds
var _flights := {}
var _unconfirmed: Array[Flight] = []
var _blasts := {}
var _query := PhysicsRayQueryParameters3D.new()
var _meshes := {}


## Flight is the picture of a projectile: its state at tick at, where it was a
## tick before, for drawing between them, and the node that shows it.
class Flight:
	var projectile: Projectile
	var previous := Vector3.ZERO
	var at := 0
	var own := false
	## stopped is set when the client's flight burst; it waits for the
	## server's blast.
	var stopped := false
	var heard := false
	var node: MeshInstance3D
	## drawn is where it was drawn last; smoke how far it flew since its last
	## puff.
	var drawn := Vector3.INF
	var smoke := 0.0


func _ready() -> void:
	var rocket := CylinderMesh.new()
	rocket.top_radius = 0.035
	rocket.bottom_radius = 0.05
	rocket.height = 0.55
	rocket.radial_segments = 8
	rocket.material = _paint(Color8(88, 96, 70))
	_meshes[WeaponTuning.Kind.ROCKET_LAUNCHER] = rocket
	var grenade := SphereMesh.new()
	grenade.radius = 0.06
	grenade.height = 0.13
	grenade.radial_segments = 8
	grenade.rings = 4
	grenade.material = _paint(Color8(70, 82, 52))
	_meshes[WeaponTuning.Kind.GRENADE] = grenade
	# A tank shell flies too fast to see but by its glowing tracer.
	var shell := CylinderMesh.new()
	shell.top_radius = 0.05
	shell.bottom_radius = 0.05
	shell.height = 1.4
	shell.radial_segments = 6
	var glow := _paint(Color8(255, 214, 140))
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shell.material = glow
	_meshes[WeaponTuning.Kind.TANK_CANNON] = shell


static func _paint(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.7
	return material


## predict starts the flight of a projectile the player's own soldier fired
## at a tick of its prediction.
func predict(shot: Shot, soldier: Soldier, tick: int) -> void:
	var tuning := rules.weapons.get_tuning(shot.weapon)
	var flight := _start(Projectile.launch(0, shot, soldier, tuning, tick), true)
	flight.heard = true
	_unconfirmed.append(flight)


## launched takes the server's word of a projectile: an own one it has flown
## already takes its number, any other starts its flight.
func launched(event: Messages.Launch, own: int) -> void:
	if event.owner == own:
		for flight in _unconfirmed:
			if flight.projectile.kind == event.kind:
				_unconfirmed.erase(flight)
				flight.projectile.id = event.projectile
				_flights[event.projectile] = flight
				return
	var projectile := Projectile.new()
	projectile.id = event.projectile
	projectile.kind = event.kind
	projectile.owner = event.owner
	projectile.position = event.position
	projectile.velocity = event.velocity
	projectile.launched = event.tick
	_flights[event.projectile] = _start(projectile, event.owner == own)


## burst takes the server's word of a blast, to show when its time comes.
func burst(event: Messages.Blast) -> void:
	_blasts[event.projectile] = event


func _start(projectile: Projectile, own: bool) -> Flight:
	var flight := Flight.new()
	flight.projectile = projectile
	flight.previous = projectile.position
	flight.at = projectile.launched
	flight.own = own
	var mesh: Mesh = _meshes.get(projectile.kind)
	if mesh != null:
		flight.node = MeshInstance3D.new()
		flight.node.mesh = mesh
		flight.node.visible = false
		add_child(flight.node)
	return flight


## update flies every projectile to the time the player sees it at: render for
## those of others, present for the own; and shows the blasts whose time came.
func update(render: float, present: float) -> void:
	var state := get_world_3d().direct_space_state
	for id: int in _flights.keys():
		var flight: Flight = _flights[id]
		if not _fly(flight, present if flight.own else render, state):
			_drop(flight)
			_flights.erase(id)
	for flight: Flight in _unconfirmed.duplicate():
		if present - flight.projectile.launched > ORPHAN_TICKS or not _fly(flight, present, state):
			_drop(flight)
			_unconfirmed.erase(flight)
	for id: int in _blasts.keys():
		var event: Messages.Blast = _blasts[id]
		var flight: Flight = _flights.get(id)
		var view := present if flight != null and flight.own else render
		if view < event.tick:
			continue
		_blasts.erase(id)
		if flight != null:
			_drop(flight)
			_flights.erase(id)
		var tuning := rules.weapons.get_tuning(event.kind)
		if tuning == null:
			continue
		if effects != null:
			effects.blast(event.position, tuning.blast_radius)
		if sounds != null:
			sounds.blast(event.position)
		blasted.emit(event.position, tuning.blast_radius, float(event.tick))


## _fly moves a flight on to the time view and draws it there. It returns false
## for a flight that is lost: its blast never came.
func _fly(flight: Flight, view: float, state: PhysicsDirectSpaceState3D) -> bool:
	var projectile := flight.projectile
	var tuning := rules.weapons.get_tuning(projectile.kind)
	if tuning == null:
		return false
	if view < projectile.launched:
		return true
	if not flight.heard:
		flight.heard = true
		if sounds != null:
			sounds.shot_at(projectile.kind, projectile.position)
	var last := ceili(view)
	while flight.at < last and not flight.stopped:
		flight.previous = projectile.position
		flight.stopped = projectile.step(state, _query, tuning, flight.at)
		flight.at += 1
	var life := tuning.fuse_ticks() if tuning.fuse > 0 else ceili(tuning.range / tuning.projectile_speed * Game.TICK_RATE)
	if view - projectile.launched > life + LOST_TICKS:
		return false
	if flight.node == null:
		return true
	# A rocket that struck waits out of sight for the server's blast; a
	# grenade lies where it came to rest.
	flight.node.visible = not (flight.stopped and tuning.bounce <= 0)
	var shown := flight.previous.lerp(projectile.position, clampf(1.0 - (flight.at - view), 0.0, 1.0))
	var basis := Basis()
	if projectile.velocity.length() > 0.1:
		var along := projectile.velocity.normalized()
		var side := along.cross(Vector3.UP if absf(along.y) < 0.99 else Vector3.RIGHT).normalized()
		basis = Basis(side, along, side.cross(along))
	flight.node.global_transform = Transform3D(basis, shown)
	# The smoke starts a few metres out, clear of the eye of the one who fired.
	if projectile.kind == WeaponTuning.Kind.ROCKET_LAUNCHER and effects != null and not flight.stopped and flight.drawn != Vector3.INF and projectile.travelled > TRAIL_START:
		flight.smoke += flight.drawn.distance_to(shown)
		while flight.smoke >= TRAIL_SPACING:
			flight.smoke -= TRAIL_SPACING
			effects.trail(shown - projectile.velocity.normalized() * (0.3 + flight.smoke))
	flight.drawn = shown
	return true


func _drop(flight: Flight) -> void:
	if flight.node != null:
		flight.node.queue_free()
