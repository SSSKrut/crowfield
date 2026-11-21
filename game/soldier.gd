class_name Soldier
extends RefCounted
## Soldier is a combat body in the world, driven by a player or a bot. Humans
## and bots share combat rules, but a human moves through InputCommand and a
## physics capsule, while a bot is driven by the server directly. position is
## the point between the feet.

var id := 0
var team: int = Game.Team.NONE
var controller: int = Game.Controller.NONE
## player or bot is the number of whoever drives the soldier.
var player := 0
var bot := 0
var alive := false
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var grounded := false
var crouched := false
## health runs from Game.MAX_HEALTH down to zero, at which the soldier dies.
var health := 0
var arsenal := Arsenal.new()
## shots counts the rounds the soldier fired, wrapping; clients show the
## shots of others from it.
var shots := 0
## The last hit the soldier took, which every client sees: a counter that
## changes with each hit, the hitbox, and the yaw the shot travelled along.
## The client shows the hit with it, and the fall when it killed.
var hit_count := 0
var hit_box := 0
var hit_yaw := 0.0


func copy() -> Soldier:
	var other := Soldier.new()
	other.id = id
	other.team = team
	other.controller = controller
	other.player = player
	other.bot = bot
	other.alive = alive
	other.position = position
	other.velocity = velocity
	other.yaw = yaw
	other.pitch = pitch
	other.grounded = grounded
	other.crouched = crouched
	other.health = health
	other.arsenal = arsenal.copy()
	other.shots = shots
	other.hit_count = hit_count
	other.hit_box = hit_box
	other.hit_yaw = hit_yaw
	return other


func is_bot() -> bool:
	return controller == Game.Controller.BOT
