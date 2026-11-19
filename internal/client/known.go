package client

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"ravenfield/internal/network/transport"
)

// DefaultPort is the server port when an address names none.
const DefaultPort = "7777"

// withDefaultPort adds the default port to an address without one.
func withDefaultPort(address string) string {
	if _, _, err := net.SplitHostPort(address); err == nil {
		return address
	}
	return net.JoinHostPort(strings.Trim(address, "[]"), DefaultPort)
}

// knownServers remembers the certificate fingerprint of every server the
// client joined, like the known hosts of SSH: the first connection trusts
// the server, later ones make sure it is still the same.
type knownServers struct {
	path    string
	servers map[string]transport.Fingerprint
}

// loadKnownServers reads the file; a missing one is empty.
func loadKnownServers(path string) (*knownServers, error) {
	known := &knownServers{path: path, servers: make(map[string]transport.Fingerprint)}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return known, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		fields := strings.Fields(text)
		if len(fields) != 2 {
			return nil, fmt.Errorf("%s:%d: want an address and a fingerprint", path, line)
		}
		fingerprint, err := transport.ParseFingerprint(fields[1])
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, line, err)
		}
		known.servers[fields[0]] = fingerprint
	}
	return known, scanner.Err()
}

func (k *knownServers) lookup(address string) (transport.Fingerprint, bool) {
	fingerprint, ok := k.servers[address]
	return fingerprint, ok
}

// remember stores the fingerprint of a server and rewrites the file.
func (k *knownServers) remember(address string, fingerprint transport.Fingerprint) error {
	k.servers[address] = fingerprint
	addresses := make([]string, 0, len(k.servers))
	for address := range k.servers {
		addresses = append(addresses, address)
	}
	sort.Strings(addresses)
	var text strings.Builder
	text.WriteString("# Servers this client joined: address and certificate fingerprint.\n")
	for _, address := range addresses {
		fmt.Fprintf(&text, "%s %s\n", address, k.servers[address])
	}
	if err := os.MkdirAll(filepath.Dir(k.path), 0o700); err != nil {
		return err
	}
	temporary := k.path + ".new"
	if err := os.WriteFile(temporary, []byte(text.String()), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, k.path)
}

// checkServer decides whether to trust the server at address, which showed
// the certificate fingerprint seen. A fingerprint given by the player must
// match; otherwise a remembered one must, and the first one is remembered.
func checkServer(known *knownServers, address string, given *transport.Fingerprint, seen transport.Fingerprint) (string, error) {
	if given != nil {
		if seen != *given {
			return "", fmt.Errorf("the server at %s has certificate fingerprint %s, not the %s given", address, seen, *given)
		}
		if known != nil {
			if remembered, ok := known.lookup(address); !ok || remembered != seen {
				return fmt.Sprintf("remembered the fingerprint of %s in %s", address, known.path), known.remember(address, seen)
			}
		}
		return "", nil
	}
	if known == nil {
		return fmt.Sprintf("connected to %s, certificate fingerprint %s (pass -fingerprint to pin it)", address, seen), nil
	}
	remembered, ok := known.lookup(address)
	switch {
	case !ok:
		return fmt.Sprintf("first connection to %s: remembered its certificate fingerprint %s in %s", address, seen, known.path),
			known.remember(address, seen)
	case remembered != seen:
		return "", fmt.Errorf("the server at %s shows another certificate than before: fingerprint %s, remembered %s. "+
			"Someone may be in between. If the server got a new certificate, connect once with -fingerprint %s; "+
			"remembered servers are in %s", address, seen, remembered, seen, known.path)
	}
	return "", nil
}
