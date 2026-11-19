package client

import (
	"encoding/binary"
	"math"
	"math/rand/v2"

	"ravenfield/internal/game"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	sampleRate = 44100
	// Rapid fire overlaps: every weapon sound plays on shotVoices voices in turn.
	shotVoices = 6
)

// shotVolumes are the volumes of the weapons' shots, at the shooter.
var shotVolumes = [game.WeaponKinds]float32{game.WeaponAssaultRifle: 0.85, game.WeaponRifle: 1, game.WeaponPistol: 0.7}

// sounds are the sounds of the player's own weapons. There are no sound
// files yet: they are made at start from noise and tones.
type sounds struct {
	ready  bool
	shots  [game.WeaponKinds][shotVoices]rl.Sound
	next   [game.WeaponKinds]int
	dry    rl.Sound
	magOut rl.Sound
	magIn  rl.Sound
	equip  rl.Sound
	// marker ticks when a shot of the player hurt someone.
	marker rl.Sound
}

// loadSounds opens the audio device; without one the game is silent.
func loadSounds(volume float32) *sounds {
	s := &sounds{}
	if volume <= 0 {
		return s
	}
	rl.InitAudioDevice()
	if !rl.IsAudioDeviceReady() {
		return s
	}
	rl.SetMasterVolume(volume)
	s.ready = true
	for kind, voice := range map[game.WeaponKind]gunshot{
		game.WeaponAssaultRifle: {decay: 0.07, smoothing: 0.32, thump: 115, volume: 0.85},
		game.WeaponRifle:        {decay: 0.13, smoothing: 0.22, thump: 85, volume: 1},
		game.WeaponPistol:       {decay: 0.045, smoothing: 0.5, thump: 160, volume: 0.7},
	} {
		first := synthesize(0.5, voice.sample(uint64(kind)), voice.volume)
		s.shots[kind][0] = first
		for i := 1; i < shotVoices; i++ {
			s.shots[kind][i] = rl.LoadSoundAlias(first)
			rl.SetSoundVolume(s.shots[kind][i], voice.volume)
		}
	}
	s.dry = synthesize(0.05, click(0.004, 0.9, 0, 7), 0.4)
	s.magOut = synthesize(0.25, clicks(0, 0.09), 0.35)
	s.magIn = synthesize(0.25, clicks(0, 0.12), 0.5)
	s.equip = synthesize(0.2, clicks(0, 0.06), 0.3)
	s.marker = synthesize(0.08, tone(2400, 0.015), 0.35)
	return s
}

// tone is a short beep of the given pitch that fades with decay.
func tone(pitch, decay float32) func(t float32) float32 {
	return func(t float32) float32 {
		return float32(math.Sin(2*math.Pi*float64(pitch*t)) * math.Exp(-float64(t/decay)))
	}
}

// hitMarker ticks for a shot that hurt someone, higher for a kill.
func (s *sounds) hitMarker(killed bool) {
	if !s.ready {
		return
	}
	pitch := float32(1)
	if killed {
		pitch = 0.75
	}
	rl.SetSoundPitch(s.marker, pitch)
	rl.PlaySound(s.marker)
}

// shotAt plays another soldier's shot from where it was fired, quieter with
// distance, to the side it came from: pan is the share of the direction to
// the shot along the listener's right.
func (s *sounds) shotAt(kind game.WeaponKind, distance, pan float32) {
	if !s.ready || kind >= game.WeaponKinds || s.shots[kind][0].FrameCount == 0 {
		return
	}
	volume := 1 / (1 + distance/12)
	if volume < 0.03 {
		return
	}
	sound := s.shots[kind][s.next[kind]]
	s.next[kind] = (s.next[kind] + 1) % shotVoices
	rl.SetSoundVolume(sound, volume*shotVolumes[kind])
	rl.SetSoundPan(sound, max(-1, min(1, pan)))
	rl.PlaySound(sound)
}

func (s *sounds) close() {
	if !s.ready {
		return
	}
	for kind := range s.shots {
		if s.shots[kind][0].FrameCount == 0 {
			continue
		}
		for i := 1; i < shotVoices; i++ {
			rl.UnloadSoundAlias(s.shots[kind][i])
		}
		rl.UnloadSound(s.shots[kind][0])
	}
	for _, sound := range []rl.Sound{s.dry, s.magOut, s.magIn, s.equip, s.marker} {
		rl.UnloadSound(sound)
	}
	rl.CloseAudioDevice()
}

// weapon plays what the player's own weapon did in a tick.
func (s *sounds) weapon(kind game.WeaponKind, events game.WeaponEvents) {
	if !s.ready {
		return
	}
	if events.Has(game.EventFired) && kind < game.WeaponKinds && s.shots[kind][0].FrameCount > 0 {
		sound := s.shots[kind][s.next[kind]]
		s.next[kind] = (s.next[kind] + 1) % shotVoices
		rl.SetSoundVolume(sound, shotVolumes[kind])
		rl.SetSoundPan(sound, 0)
		rl.PlaySound(sound)
	}
	if events.Has(game.EventDryFire) {
		rl.PlaySound(s.dry)
	}
	if events.Has(game.EventReloadStarted) {
		rl.PlaySound(s.magOut)
	}
	if events.Has(game.EventReloaded) {
		rl.PlaySound(s.magIn)
	}
	if events.Has(game.EventEquipStarted) {
		rl.PlaySound(s.equip)
	}
}

// gunshot is a burst of filtered noise over a falling thump.
type gunshot struct {
	// decay is the time constant of the noise in seconds, smoothing how much
	// of each new noise sample passes the low-pass filter.
	decay, smoothing float32
	// thump is the starting pitch of the low tone, in Hz.
	thump, volume float32
}

func (g gunshot) sample(seed uint64) func(t float32) float32 {
	random := rand.New(rand.NewPCG(seed, 0x5a11))
	filtered := float32(0)
	phase := float64(0)
	return func(t float32) float32 {
		filtered += g.smoothing * (random.Float32()*2 - 1 - filtered)
		noise := filtered * float32(math.Exp(-float64(t/g.decay)))
		pitch := float64(g.thump) * (0.5 + 0.5*math.Exp(-float64(t)/0.04))
		phase += 2 * math.Pi * pitch / sampleRate
		tone := float32(math.Sin(phase) * math.Exp(-float64(t)/0.035))
		attack := min(1, t/0.0015)
		return attack * (1.6*noise + 0.8*tone)
	}
}

// click is a short tick of bright noise starting at a time.
func click(decay, smoothing, at float32, seed uint64) func(t float32) float32 {
	random := rand.New(rand.NewPCG(seed, 0xc11c))
	filtered := float32(0)
	return func(t float32) float32 {
		filtered += smoothing * (random.Float32()*2 - 1 - filtered)
		if t < at {
			return 0
		}
		return filtered * float32(math.Exp(-float64((t-at)/decay)))
	}
}

// clicks are the two clicks of a magazine or a slide, at the given times.
func clicks(first, second float32) func(t float32) float32 {
	a := click(0.006, 0.8, first, 3)
	b := click(0.01, 0.6, second, 5)
	return func(t float32) float32 {
		return a(t) + b(t)
	}
}

// synthesize renders seconds of a sample function into a sound played at the
// given volume, scaled so that its loudest sample is at 0.9 of the full range.
func synthesize(seconds float32, sample func(t float32) float32, volume float32) rl.Sound {
	count := int(seconds * sampleRate)
	values := make([]float32, count)
	peak := float32(1e-6)
	for i := range values {
		values[i] = sample(float32(i) / sampleRate)
		peak = max(peak, float32(math.Abs(float64(values[i]))))
	}
	data := make([]byte, 2*count)
	for i, value := range values {
		binary.LittleEndian.PutUint16(data[2*i:], uint16(int16(value/peak*0.9*math.MaxInt16)))
	}
	sound := rl.LoadSoundFromWave(rl.NewWave(uint32(count), sampleRate, 16, 1, data))
	rl.SetSoundVolume(sound, volume)
	return sound
}
