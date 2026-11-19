package simulation

import "ravenfield/internal/game"

// inputWindow is how far ahead of the server a command may arrive: one second.
const inputWindow = game.TickRate

// inputBuffer holds a player's commands by tick until the server runs that
// tick. Each datagram repeats several recent commands, so most arrive more
// than once; the copies land in the same slot.
type inputBuffer struct {
	commands [inputWindow]game.InputCommand
	present  [inputWindow]bool
}

// put accepts commands for the current tick and up to a second ahead. Late
// commands are useless and commands from the far future would block slots.
func (b *inputBuffer) put(command game.InputCommand, current game.Tick) bool {
	if command.Tick-current >= inputWindow {
		return false
	}
	slot := command.Tick % inputWindow
	b.commands[slot], b.present[slot] = command, true
	return true
}

func (b *inputBuffer) take(tick game.Tick) (game.InputCommand, bool) {
	slot := tick % inputWindow
	command := b.commands[slot]
	ok := b.present[slot] && command.Tick == tick
	b.present[slot] = false
	return command, ok
}

// waiting counts the commands for ticks after the given one. The client keeps
// this near its target lead; the server reports it in every snapshot.
func (b *inputBuffer) waiting(after game.Tick) int {
	count := 0
	for slot, present := range b.present {
		if ahead := b.commands[slot].Tick - after; present && ahead >= 1 && ahead < inputWindow {
			count++
		}
	}
	return count
}
