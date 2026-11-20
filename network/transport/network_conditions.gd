class_name NetworkConditions
extends RefCounted
## NetworkConditions describe a simulated network path. delay is one way and
## applies in both directions, so the round trip gains 2 × (delay + jitter/2).
## jitter adds a uniform extra delay in [0, jitter), which also reorders
## datagrams. loss and duplicate are shares of datagrams; reliable messages are
## only delayed and stay in order. Times are in seconds.

var delay := 0.0
var jitter := 0.0
var loss := 0.0
var duplicate := 0.0
var seed := 0


## parse reads the -netsim flag format, for example
## "delay=50ms,jitter=10ms,loss=3%,dup=1%,seed=7". An empty string means none.
## It returns the conditions, or the error as a String.
static func parse(text: String) -> Variant:
	var conditions := NetworkConditions.new()
	if text.strip_edges() == "":
		return conditions
	for part in text.split(","):
		var pair := part.strip_edges().split("=")
		if pair.size() != 2:
			return "network condition %s is not key=value" % part
		var key := pair[0]
		var value := pair[1]
		match key:
			"delay", "jitter":
				var seconds: Variant = Flags.Duration.parse(value)
				if seconds == null:
					return "network condition %s: bad duration %s" % [key, value]
				conditions.set(key, seconds)
			"loss", "dup":
				var share := _share(value)
				if share < 0:
					return "network condition %s: bad share %s" % [key, value]
				conditions.set("loss" if key == "loss" else "duplicate", share)
			"seed":
				if not value.is_valid_int():
					return "network condition seed: bad number %s" % value
				conditions.seed = value.to_int()
			_:
				return "unknown network condition %s" % key
	var error := conditions.validate()
	if error != "":
		return error
	return conditions


static func _share(text: String) -> float:
	if text.ends_with("%"):
		var number := text.trim_suffix("%")
		return number.to_float() / 100.0 if number.is_valid_float() else -1.0
	return text.to_float() if text.is_valid_float() else -1.0


func validate() -> String:
	if delay < 0 or jitter < 0:
		return "delay and jitter must not be negative"
	if loss < 0 or loss >= 1:
		return "loss must be at least 0% and below 100%"
	if duplicate < 0 or duplicate > 1:
		return "duplication must be between 0% and 100%"
	return ""


func is_none() -> bool:
	return delay == 0 and jitter == 0 and loss == 0 and duplicate == 0


func _to_string() -> String:
	return "delay=%dms,jitter=%dms,loss=%s%%,dup=%s%%" % [roundi(delay * 1000), roundi(jitter * 1000), str(snappedf(loss * 100, 0.01)), str(snappedf(duplicate * 100, 0.01))]
