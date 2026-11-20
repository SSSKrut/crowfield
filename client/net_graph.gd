class_name NetGraph
extends RefCounted
## NetGraph is the client's network record (ARCHITECTURE.md, 6.13), shown with
## F2: the last few seconds by bucket, and averages of the last second.

## The graph keeps BUCKETS buckets of BUCKET seconds each.
const BUCKETS := 60
const BUCKET := 0.1
## RECENT is how many of the newest buckets the text averages over.
const RECENT := 10

var buckets: Array[Bucket] = []
var current := 0
var _elapsed := 0.0
var _sequence := 0
var _started := false
## The soldier under the crosshair and how many updates it had, to count its
## update rate.
var _aimed := 0
var _aimed_updates := 0


func _init() -> void:
	for i in BUCKETS:
		buckets.append(Bucket.new())


func bucket() -> Bucket:
	return buckets[current]


## datagram records a snapshot datagram of the given size.
func datagram(size: int, snapshot: Snapshot) -> void:
	var b := bucket()
	b.bytes += size
	b.datagrams += 1
	if not _started:
		_sequence = snapshot.sequence
		_started = true
		b.expected += 1
	else:
		var gap := Game.sequence_difference(snapshot.sequence, _sequence)
		if gap > 0:
			_sequence = snapshot.sequence
			b.expected += gap
	var lead := snapshot.player.input_lead
	if snapshot.player.processed and lead != PlayerState.NO_INPUT:
		if not b.has_lead or lead < b.lead:
			b.lead = lead
			b.has_lead = true
		if lead < 0:
			b.late += 1


## correction records a correction of the prediction of the given size.
func correction(size: float) -> void:
	var b := bucket()
	b.corrections += 1
	b.correction = maxf(b.correction, size)
	b.has_correction = true


## frame advances the graph by a frame. aimed is the soldier nearest to the
## crosshair, zero for none, and updates how many states the client has had of
## it so far.
func frame(delta: float, rtt: float, dilation: float, aimed: int, updates: int) -> void:
	var b := bucket()
	if aimed != 0 and aimed == _aimed:
		b.aimed_updates += updates - _aimed_updates
	_aimed = aimed
	_aimed_updates = updates
	b.rtt = rtt
	b.dilation = dilation
	_elapsed += delta
	if _elapsed >= BUCKET:
		_elapsed -= BUCKET
		current = (current + 1) % BUCKETS
		buckets[current] = Bucket.new()


## recent sums the last second, without the bucket still filling.
func recent() -> Bucket:
	var sum := Bucket.new()
	for i in range(1, RECENT + 1):
		var b := buckets[(current - i + BUCKETS) % BUCKETS]
		sum.bytes += b.bytes
		sum.datagrams += b.datagrams
		sum.expected += b.expected
		sum.late += b.late
		sum.corrections += b.corrections
		sum.correction = maxf(sum.correction, b.correction)
		sum.aimed_updates += b.aimed_updates
		if b.has_lead and (not sum.has_lead or b.lead < sum.lead):
			sum.lead = b.lead
			sum.has_lead = true
	var last := buckets[(current - 1 + BUCKETS) % BUCKETS]
	sum.rtt = last.rtt
	sum.dilation = last.dilation
	return sum


## draw shows the graph with its top left corner at origin, at a scale of the
## 720 pixel screen: the smallest input lead of every bucket against the
## target, and the snapshot traffic, with the averages of the last second
## below. jumps are the clock jumps of the session.
func draw(canvas: CanvasItem, font: Font, jumps: int, origin: Vector2, scale: float = 1.0) -> void:
	const WIDTH := 360.0
	const HEIGHT := 70.0
	const BAR := WIDTH / BUCKETS
	## LEAD_SCALE is in pixels per tick of lead.
	const LEAD_SCALE := 6.0
	const SKY_BLUE := Color8(102, 191, 255)
	const LATE := Color8(230, 41, 55)
	const CORRECTION := Color8(255, 161, 0)
	const TRAFFIC := Color8(255, 203, 0)
	const LABEL := Color8(200, 200, 200)
	var sum := recent()
	var loss := 0.0
	if sum.expected > 0:
		loss = 100 * maxf(0.0, 1 - float(sum.datagrams) / sum.expected)
	var text: PackedStringArray = [
		"RTT %d ms | snapshot loss %.1f%%" % [roundi(sum.rtt * 1000), loss],
		"snapshots %.1f KB/s, %d datagrams/s" % [sum.bytes / 1024.0, sum.datagrams],
		"input lead %d (target %d) | clock %+.1f%% | jumps %d | late %d/s" % [sum.lead, ClientSession.COMMAND_LEAD, 100 * sum.dilation, jumps, sum.late],
		"corrections %d/s (largest %.3f m) | aimed soldier %d Hz" % [sum.corrections, sum.correction, sum.aimed_updates],
	]
	var box := func(x: float, y: float, width: float, height: float, color: Color) -> void:
		canvas.draw_rect(Rect2(origin + Vector2(x, y) * scale, Vector2(width, height) * scale), color)
	var write := func(line: String, x: float, y: float, size: int, color: Color) -> void:
		var scaled := maxi(1, roundi(size * scale))
		canvas.draw_string(font, origin + Vector2(x, y) * scale + Vector2(0, 0.8 * scaled), line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, scaled, color)
	box.call(-6, -6, WIDTH + 12, 2 * HEIGHT + 16 + text.size() * 20, Color8(0, 0, 0, 140))
	# Input lead: the target as a line, every bucket's smallest lead as a bar
	# from zero, red when commands came late.
	var zero := HEIGHT - 10
	var target := zero - ClientSession.COMMAND_LEAD * LEAD_SCALE
	box.call(0, target, WIDTH, 1, Color8(0, 117, 44))
	box.call(0, zero, WIDTH, 1, Color8(130, 130, 130))
	for i in BUCKETS:
		var b := buckets[(current + 1 + i) % BUCKETS]
		if not b.has_lead:
			continue
		var x := i * BAR
		var lead := clampi(b.lead, -1, 9) * LEAD_SCALE
		if b.lead < 0:
			box.call(x, zero, BAR - 1, LEAD_SCALE, LATE)
		else:
			box.call(x, zero - lead, BAR - 1, lead + 1, SKY_BLUE)
		if b.has_correction:
			box.call(x, 0, BAR - 1, 4, CORRECTION)
	# Snapshot traffic per bucket, scaled to 64 KB/s at the top.
	var base := 2 * HEIGHT + 4
	for i in BUCKETS:
		var b := buckets[(current + 1 + i) % BUCKETS]
		var bar := minf(b.bytes / BUCKET / (64 * 1024) * HEIGHT, HEIGHT)
		box.call(i * BAR, base - bar, BAR - 1, bar, TRAFFIC)
	write.call("input lead", WIDTH - 80, 0, 14, LABEL)
	write.call("snapshot bytes", WIDTH - 110, HEIGHT + 8, 14, LABEL)
	for i in text.size():
		write.call(text[i], 0, base + 8 + i * 20, 16, Color(1, 1, 1))


## Bucket is what happened on the network during one bucket of time.
class Bucket:
	var bytes := 0
	var datagrams := 0
	## expected counts the snapshot sequences that went by, for the loss.
	var expected := 0
	## lead is the smallest input lead the server reported, if any; late counts
	## snapshots that reported commands arriving late.
	var lead := 0
	var has_lead := false
	var late := 0
	var corrections := 0
	var correction := 0.0
	var has_correction := false
	var aimed_updates := 0
	var rtt := 0.0
	var dilation := 0.0
