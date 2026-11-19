package client

import (
	"fmt"
	"image/color"
	"math"
	"strings"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	markerTime = 0.25
	// A damage indicator shows hurtTime, the red flash of a hit hurtFlash.
	hurtTime  = 1.5
	hurtFlash = 0.25
	// The kill feed keeps feedLength lines, each for feedTime.
	feedLength = 5
	feedTime   = 6
)

// hurtMark points where a hit came from: yaw is the direction from the
// player towards the shooter.
type hurtMark struct {
	yaw, age float32
}

type feedLine struct {
	killer, victim         string
	killerTeam, victimTeam game.Team
	weapon                 game.WeaponKind
	head, own              bool
	age                    float32
}

// feedback is what the events of combat show the player: a marker on the
// crosshair when its shot hurt someone, where hits on it came from, the kill
// feed, and who killed it.
type feedback struct {
	marker     float32
	markerKill bool
	markerHead bool
	hurt       []hurtMark
	flash      float32
	feed       []feedLine
	// killedBy tells the death screen about the last death of the own soldier.
	killedBy string
}

// take shows the events a poll brought; own is the player's soldier.
func (f *feedback) take(events []protocol.Message, own game.SoldierID, sounds *sounds) {
	for _, event := range events {
		switch event := event.(type) {
		case *protocol.HitConfirm:
			f.marker, f.markerKill, f.markerHead = markerTime, event.Killed, event.Zone == game.ZoneHead
			sounds.hitMarker(event.Killed)
		case *protocol.Damage:
			yaw := float32(event.Yaw)*(2*math.Pi/256) + math.Pi
			if len(f.hurt) == 8 {
				f.hurt = f.hurt[1:]
			}
			f.hurt = append(f.hurt, hurtMark{yaw: yaw})
			f.flash = hurtFlash
		case *protocol.Death:
			line := feedLine{
				killer: event.KillerName, victim: event.VictimName, killerTeam: event.KillerTeam, victimTeam: event.VictimTeam,
				weapon: event.Weapon, head: event.Zone == game.ZoneHead, own: event.Killer == own || event.Victim == own,
			}
			if len(f.feed) == feedLength {
				f.feed = f.feed[1:]
			}
			f.feed = append(f.feed, line)
			if event.Victim == own {
				f.killedBy = fmt.Sprintf("Killed by %s with the %s", event.KillerName, game.WeaponKind(event.Weapon))
				if line.head {
					f.killedBy += ", in the head"
				}
			}
		}
	}
}

func (f *feedback) update(deltaTime float32) {
	f.marker = max(0, f.marker-deltaTime)
	f.flash = max(0, f.flash-deltaTime)
	kept := f.hurt[:0]
	for _, mark := range f.hurt {
		if mark.age += deltaTime; mark.age < hurtTime {
			kept = append(kept, mark)
		}
	}
	f.hurt = kept
	lines := f.feed[:0]
	for _, line := range f.feed {
		if line.age += deltaTime; line.age < feedTime {
			lines = append(lines, line)
		}
	}
	f.feed = lines
}

// draw draws the feedback for a view looking along yaw.
func (f *feedback) draw(yaw float32, teams map[game.Team]color.RGBA) {
	width, height := float32(rl.GetScreenWidth()), float32(rl.GetScreenHeight())
	center := rl.NewVector2(width/2, height/2)
	if f.flash > 0 {
		alpha := uint8(110 * f.flash / hurtFlash)
		rl.DrawRectangleGradientV(0, 0, int32(width), int32(height/5), rl.NewColor(200, 0, 0, alpha), rl.NewColor(200, 0, 0, 0))
		rl.DrawRectangleGradientV(0, int32(height*4/5), int32(width), int32(height/5), rl.NewColor(200, 0, 0, 0), rl.NewColor(200, 0, 0, alpha))
	}
	for _, mark := range f.hurt {
		// Straight ahead is up on the screen; the arc's angle counts from
		// the right, clockwise, as raylib draws rings.
		relative := float64(mark.yaw - yaw)
		angle := float32(math.Remainder(relative, 2*math.Pi)*180/math.Pi) - 90
		alpha := uint8(220 * (1 - mark.age/hurtTime))
		rl.DrawRing(center, 110, 124, angle-22, angle+22, 16, rl.NewColor(230, 30, 30, alpha))
	}
	if f.marker > 0 {
		tint := rl.White
		size := float32(10)
		if f.markerHead {
			tint = rl.Gold
		}
		if f.markerKill {
			tint, size = rl.Red, 14
		}
		tint.A = uint8(255 * min(1, 2*f.marker/markerTime))
		for _, corner := range [4][2]float32{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}} {
			inner := rl.NewVector2(center.X+corner[0]*5, center.Y+corner[1]*5)
			outer := rl.NewVector2(center.X+corner[0]*size, center.Y+corner[1]*size)
			rl.DrawLineEx(inner, outer, 2.5, tint)
		}
	}
	right, y := int32(width)-24, int32(140)
	for _, line := range f.feed {
		weapon := "[" + strings.ToUpper(line.weapon.String()) + "]"
		if line.head {
			weapon += " HEADSHOT"
		}
		parts := []struct {
			text string
			tint color.RGBA
		}{{line.killer, teams[line.killerTeam]}, {"  " + weapon + "  ", rl.LightGray}, {line.victim, teams[line.victimTeam]}}
		total := int32(0)
		for _, part := range parts {
			total += rl.MeasureText(part.text, 18)
		}
		background := rl.NewColor(0, 0, 0, 110)
		if line.own {
			background = rl.NewColor(120, 100, 20, 140)
		}
		rl.DrawRectangle(right-total-8, y-4, total+16, 26, background)
		x := right - total
		for _, part := range parts {
			rl.DrawText(part.text, x, y, 18, part.tint)
			x += rl.MeasureText(part.text, 18)
		}
		y += 30
	}
}
