package game

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultMovementTuningIsValid(t *testing.T) {
	if err := DefaultMovementTuning().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestLoadMovementTuningOverridesDefaults(t *testing.T) {
	path := writeTuning(t, `{"sprint_speed": 9.5, "jump_speed": 5}`)
	tuning, err := LoadMovementTuning(path)
	if err != nil {
		t.Fatal(err)
	}
	want := DefaultMovementTuning()
	want.SprintSpeed = 9.5
	want.JumpSpeed = 5
	if tuning != want {
		t.Errorf("loaded %+v, want %+v", tuning, want)
	}
}

func TestLoadMovementTuningRejectsBadFiles(t *testing.T) {
	for name, content := range map[string]string{
		"unknown field": `{"walk_sped": 4}`,
		"bad value":     `{"gravity": 0}`,
		"eye too high":  `{"eye_height": 3}`,
		"not json":      `walk_speed = 4`,
	} {
		if _, err := LoadMovementTuning(writeTuning(t, content)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := LoadMovementTuning(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Error("missing file accepted")
	}
}

func writeTuning(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "movement.json")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}
