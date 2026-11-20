GODOT ?= godot
# Flags after the target's own, e.g. make client ARGS="-dummies=64".
ARGS ?=

.PHONY: import client server loadtest test

# import registers the scripts and imports the assets; the other targets need
# it once after a checkout and after new scripts appear.
import:
	$(GODOT) --headless --path . --import

client: import
	$(GODOT) --path . -- $(ARGS)

server: import
	$(GODOT) --headless --path . -- server $(ARGS)

loadtest: import
	$(GODOT) --headless --path . -- loadtest $(ARGS)

test: import
	$(GODOT) --headless --path . -- test $(ARGS)
