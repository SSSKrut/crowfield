class_name Baselines
extends RefCounted
## Baselines keeps what a client received of each soldier, the
## SoldierRecord.BASE_HISTORY newest states by datagram sequence, and resolves
## deltas against them.

## _soldiers maps a soldier to [sequences: PackedInt32Array, states: Array].
var _soldiers := {}


## resolve returns the full state that a record of the datagram with the given
## sequence describes, or the error as a String.
func resolve(sequence: int, record: SoldierRecord) -> Variant:
	if record.base == 0:
		return record.resolve(null)
	var base: SoldierState = null
	var received: Variant = _soldiers.get(record.state.id)
	if received != null:
		var want := (sequence - record.base) & 0xFFFF
		var sequences: PackedInt32Array = received[0]
		var index := sequences.find(want)
		if index >= 0:
			base = received[1][index]
	return record.resolve(base)


## store keeps a state received in the datagram with the given sequence as a
## possible base, unless BASE_HISTORY newer states of the soldier are kept.
func store(sequence: int, state: SoldierState) -> void:
	var received: Variant = _soldiers.get(state.id)
	if received == null:
		received = [PackedInt32Array(), []]
		_soldiers[state.id] = received
	var sequences: PackedInt32Array = received[0]
	var states: Array = received[1]
	var index := sequences.find(sequence)
	if index >= 0:
		states[index] = state
		return
	if sequences.size() < SoldierRecord.BASE_HISTORY:
		sequences.append(sequence)
		states.append(state)
		received[0] = sequences
		return
	var oldest := 0
	for i in range(1, sequences.size()):
		if Game.sequence_difference(sequences[i], sequences[oldest]) < 0:
			oldest = i
	if Game.sequence_difference(sequence, sequences[oldest]) < 0:
		return
	sequences[oldest] = sequence
	states[oldest] = state
	received[0] = sequences


## forget drops what was received of a soldier that is gone.
func forget(id: int) -> void:
	_soldiers.erase(id)
