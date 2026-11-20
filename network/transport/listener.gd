class_name Listener
extends RefCounted
## Listener accepts connections. Like connections it is polled: poll() takes in
## new peers and services the ones accepted, accept() hands out the new ones.

## accept returns the next new connection, or null.
func accept() -> Conn:
	return null


func poll() -> void:
	pass


## flush pushes out what the accepted connections sent since the last poll.
func flush() -> void:
	pass


## close stops accepting and ends every connection accepted from it.
func close() -> void:
	pass


func address() -> String:
	return ""
