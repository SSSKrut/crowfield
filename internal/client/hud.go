package client

import (
	"fmt"
	"image/color"
	"math"
	"strings"

	"ravenfield/internal/game"

	rl "github.com/gen2brain/raylib-go/raylib"
)

var weaponLabels = [game.WeaponKinds]string{"", "Assault rifle", "Rifle", "Pistol"}

// drawCrosshair draws four ticks around the middle of the screen, as far
// apart as the spread of the next shot at the field of view fovy, in
// degrees. Aiming down the sights shrinks it to a dot.
func drawCrosshair(spread, fovy, aim float32) {
	width, height := float32(rl.GetScreenWidth()), float32(rl.GetScreenHeight())
	x, y := width/2, height/2
	gap := float32(math.Tan(float64(spread))/math.Tan(float64(fovy)*math.Pi/360)) * height / 2
	gap = max(3, gap)
	alpha := uint8(255 * (1 - aim))
	tint := rl.NewColor(255, 255, 255, alpha)
	const length, thickness = 8, 2
	if alpha > 0 {
		rl.DrawRectangleV(rl.NewVector2(x-gap-length, y-thickness/2), rl.NewVector2(length, thickness), tint)
		rl.DrawRectangleV(rl.NewVector2(x+gap, y-thickness/2), rl.NewVector2(length, thickness), tint)
		rl.DrawRectangleV(rl.NewVector2(x-thickness/2, y-gap-length), rl.NewVector2(thickness, length), tint)
		rl.DrawRectangleV(rl.NewVector2(x-thickness/2, y+gap), rl.NewVector2(thickness, length), tint)
	}
	rl.DrawCircleV(rl.NewVector2(x, y), 1.5, rl.NewColor(255, 255, 255, 200))
}

// drawScope covers the screen but a round view with a reticle.
func drawScope() {
	width, height := float32(rl.GetScreenWidth()), float32(rl.GetScreenHeight())
	center := rl.NewVector2(width/2, height/2)
	radius := 0.44 * height
	outer := float32(math.Hypot(float64(width), float64(height)))
	rl.DrawRing(center, radius, outer, 0, 360, 96, rl.Black)
	rl.DrawRing(center, radius-6, radius, 0, 360, 96, rl.NewColor(10, 10, 10, 200))
	line := rl.NewColor(10, 10, 10, 230)
	rl.DrawRectangleV(rl.NewVector2(center.X-radius, center.Y-1), rl.NewVector2(radius-12, 2), line)
	rl.DrawRectangleV(rl.NewVector2(center.X+12, center.Y-1), rl.NewVector2(radius-12, 2), line)
	rl.DrawRectangleV(rl.NewVector2(center.X-1, center.Y+12), rl.NewVector2(2, radius-12), line)
	rl.DrawRectangleV(rl.NewVector2(center.X-1, center.Y-radius), rl.NewVector2(2, radius-12), line)
	rl.DrawCircleV(center, 1.5, rl.Red)
}

// drawArsenal shows the weapon in hand and its rounds in the bottom right
// corner, the reload, and the slots of the loadout.
func drawArsenal(arsenal *game.Arsenal, weapons *game.WeaponSet) {
	kind := arsenal.Weapon()
	tuning := weapons.Get(kind)
	if tuning == nil {
		return
	}
	width, height := int32(rl.GetScreenWidth()), int32(rl.GetScreenHeight())
	right, bottom := width-24, height-24
	ammo := arsenal.Ammo[arsenal.Current]
	magazine := fmt.Sprint(ammo.Magazine)
	reserve := fmt.Sprintf("/ %d", ammo.Reserve)
	reserveWidth := rl.MeasureText(reserve, 24)
	magazineWidth := rl.MeasureText(magazine, 48)
	tint := rl.White
	if ammo.Magazine == 0 {
		tint = rl.Red
	} else if int32(ammo.Magazine) <= tuning.Magazine/4 {
		tint = rl.Orange
	}
	rl.DrawRectangle(right-230, bottom-112, 236, 118, rl.NewColor(0, 0, 0, 110))
	rl.DrawText(reserve, right-reserveWidth, bottom-26, 24, rl.LightGray)
	rl.DrawText(magazine, right-reserveWidth-10-magazineWidth, bottom-48, 48, tint)
	label := strings.ToUpper(weaponLabels[kind])
	rl.DrawText(label, right-rl.MeasureText(label, 20), bottom-76, 20, rl.White)
	if arsenal.Action != game.WeaponReady {
		total := tuning.EquipTicks()
		text := "EQUIPPING"
		if arsenal.Action == game.WeaponReloading {
			total, text = tuning.ReloadTicks(), "RELOADING"
		}
		done := 1 - float32(arsenal.ActionTicks)/float32(max(1, total))
		rl.DrawRectangle(right-220, bottom-100, 220, 6, rl.NewColor(255, 255, 255, 60))
		rl.DrawRectangle(right-220, bottom-100, int32(220*done), 6, rl.Gold)
		rl.DrawText(text, right-220, bottom-76, 16, rl.Gold)
	}
	x := right - 230
	for slot, kind := range arsenal.Weapons {
		if kind == game.WeaponNone {
			continue
		}
		text := fmt.Sprintf("%d %s", slot+1, weaponLabels[kind])
		tint := rl.NewColor(200, 200, 200, 150)
		if uint8(slot) == arsenal.Current {
			tint = rl.White
		}
		x -= rl.MeasureText(text, 16) + 18
		rl.DrawText(text, x, bottom-16, 16, tint)
	}
}

// drawHealth shows the health of the own soldier in the bottom left corner,
// and the team it fights for: the soldiers of the other colour are enemies.
func drawHealth(health uint8, team string, tint color.RGBA) {
	height := int32(rl.GetScreenHeight())
	label := strings.ToUpper(team) + " TEAM"
	rl.DrawRectangle(18, height-24-92, rl.MeasureText(label, 20)+12, 26, rl.NewColor(0, 0, 0, 110))
	rl.DrawText(label, 24, height-24-88, 20, tint)
	drawHealthBar(health)
}

func drawHealthBar(health uint8) {
	height := int32(rl.GetScreenHeight())
	left, bottom := int32(24), height-24
	share := float32(health) / game.MaxHealth
	tint := rl.NewColor(110, 220, 120, 255)
	if share <= 0.25 {
		tint = rl.Red
	} else if share <= 0.5 {
		tint = rl.Orange
	}
	rl.DrawRectangle(left-6, bottom-64, 232, 70, rl.NewColor(0, 0, 0, 110))
	rl.DrawText(fmt.Sprint(health), left, bottom-48, 48, tint)
	rl.DrawText("HEALTH", left+rl.MeasureText(fmt.Sprint(health), 48)+10, bottom-26, 20, rl.LightGray)
	rl.DrawRectangle(left, bottom-4, 220, 4, rl.NewColor(255, 255, 255, 50))
	rl.DrawRectangle(left, bottom-4, int32(220*share), 4, tint)
}

// drawDeath tells the dead player when it comes back.
func drawDeath(respawn uint16) {
	width, height := int32(rl.GetScreenWidth()), int32(rl.GetScreenHeight())
	rl.DrawRectangle(0, height/2-60, width, 120, rl.NewColor(0, 0, 0, 120))
	title := "KILLED"
	rl.DrawText(title, (width-rl.MeasureText(title, 48))/2, height/2-46, 48, rl.Red)
	back := fmt.Sprintf("Back in the fight in %.1f s", float32(respawn)/game.TickRate)
	rl.DrawText(back, (width-rl.MeasureText(back, 22))/2, height/2+14, 22, rl.White)
}
