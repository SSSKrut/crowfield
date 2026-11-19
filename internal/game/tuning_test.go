package game

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDefaultMovementTuningIsValid(t *testing.T) {
	if err := DefaultMovementTuning().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestMovementTuningHashChangesWithEveryField(t *testing.T) {
	base := DefaultMovementTuning()
	if base.Hash() != DefaultMovementTuning().Hash() {
		t.Fatal("hash is not stable")
	}
	seen := map[uint64]string{base.Hash(): "default"}
	value := reflect.ValueOf(&base).Elem()
	for i := range value.NumField() {
		changed := base
		field := reflect.ValueOf(&changed).Elem().Field(i)
		field.SetFloat(field.Float() + 0.25)
		name := value.Type().Field(i).Name
		if previous, ok := seen[changed.Hash()]; ok {
			t.Errorf("changing %s gives the same hash as %s", name, previous)
		}
		seen[changed.Hash()] = name
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
