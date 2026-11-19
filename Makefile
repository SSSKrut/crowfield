CMAKE ?= cmake
GO ?= go
NATIVE_BUILD_DIR ?= build/native
BIN_DIR ?= bin

.PHONY: all native client server loadtest run-client run-server clean

all: client server loadtest

native:
	$(CMAKE) -S native/jolt -B $(NATIVE_BUILD_DIR) -G Ninja -DCMAKE_BUILD_TYPE=Release
	$(CMAKE) --build $(NATIVE_BUILD_DIR)

client: native
	mkdir -p $(BIN_DIR)
	CGO_ENABLED=1 $(GO) build -o $(BIN_DIR)/client ./cmd/client

server: native
	mkdir -p $(BIN_DIR)
	CGO_ENABLED=1 $(GO) build -o $(BIN_DIR)/server ./cmd/server

loadtest: native
	mkdir -p $(BIN_DIR)
	CGO_ENABLED=1 $(GO) build -o $(BIN_DIR)/loadtest ./cmd/loadtest

run-client: client
	./$(BIN_DIR)/client

run-server: server
	./$(BIN_DIR)/server

clean:
	$(CMAKE) -E remove_directory build
	$(CMAKE) -E remove_directory $(BIN_DIR)
