class_name RateLimit
extends RefCounted
## RateLimit is a token bucket: rate tokens a second, at most burst kept.

var rate: float
var burst: float
var _tokens: float
var _last := -1.0


func _init(per_second: float, most: float) -> void:
	rate = per_second
	burst = most
	_tokens = most


## allow takes a token if one is left at the time now, in seconds.
func allow(now: float) -> bool:
	if _last >= 0:
		_tokens = minf(burst, _tokens + (now - _last) * rate)
	_last = now
	if _tokens < 1:
		return false
	_tokens -= 1
	return true
