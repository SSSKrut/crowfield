package client

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
)

func TestAddressesGetTheDefaultPort(t *testing.T) {
	for address, want := range map[string]string{
		"192.168.1.20":      "192.168.1.20:7777",
		"192.168.1.20:9000": "192.168.1.20:9000",
		"example.org":       "example.org:7777",
		"::1":               "[::1]:7777",
		"[::1]":             "[::1]:7777",
		"[::1]:9000":        "[::1]:9000",
	} {
		if got := withDefaultPort(address); got != want {
			t.Errorf("%q became %q, want %q", address, got, want)
		}
	}
}

// Like SSH: the first connection remembers the server, later ones must see
// the same certificate, and a fingerprint given by hand replaces the
// remembered one.
func TestKnownServersTrustOnFirstUse(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ravenfield", "known_servers")
	first, other := transport.Fingerprint{1}, transport.Fingerprint{2}
	known, err := loadKnownServers(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := checkServer(known, "host:7777", nil, first); err != nil {
		t.Fatal(err)
	}
	reloaded, err := loadKnownServers(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := checkServer(reloaded, "host:7777", nil, first); err != nil {
		t.Errorf("the remembered server was refused: %v", err)
	}
	if _, err := checkServer(reloaded, "host:7777", nil, other); err == nil || !strings.Contains(err.Error(), "-fingerprint "+other.String()) {
		t.Errorf("a changed certificate gave %v", err)
	}
	if _, err := checkServer(reloaded, "host:7777", &first, other); err == nil {
		t.Error("a certificate other than the one given was accepted")
	}
	if _, err := checkServer(reloaded, "host:7777", &other, other); err != nil {
		t.Fatal(err)
	}
	if again, _ := loadKnownServers(path); again.servers["host:7777"] != other || len(again.servers) != 1 {
		t.Errorf("after pinning the new certificate the file holds %v", again.servers)
	}
	if _, err := checkServer(nil, "host:7777", nil, other); err != nil {
		t.Errorf("without a config directory any server is taken: %v", err)
	}
	if err := os.WriteFile(path, []byte("host:7777 nothex\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadKnownServers(path); err == nil {
		t.Error("a damaged file was read")
	}
}

// A host keeps its certificate, so players who joined once trust it again;
// they connect without a fingerprint the second time too.
func TestJoiningAHostTwiceWithoutAFingerprint(t *testing.T) {
	hostDir, playerDir := t.TempDir(), t.TempDir()
	_, before, err := hostCertificate(hostDir)
	if err != nil {
		t.Fatal(err)
	}
	tuning := game.DefaultMovementTuning()
	local, err := startLocalServer(tuning, config.Client{Host: "127.0.0.1:0", ConfigDir: hostDir})
	if err != nil {
		t.Fatal(err)
	}
	defer local.stop()
	for range 2 {
		conn, err := dial(config.Client{Connect: local.network.Addr(), ConfigDir: playerDir})
		if err != nil {
			t.Fatal(err)
		}
		_ = conn.Close("test over")
	}
	known, err := loadKnownServers(filepath.Join(playerDir, "known_servers"))
	if err != nil {
		t.Fatal(err)
	}
	if known.servers[local.network.Addr()] != before {
		t.Errorf("the player remembered %v, the host's certificate is %s", known.servers, before)
	}
	if _, err := dial(config.Client{Connect: local.network.Addr(), Fingerprint: transport.Fingerprint{9}.String(), ConfigDir: playerDir}); err == nil {
		t.Error("a wrong fingerprint was accepted")
	}
}
