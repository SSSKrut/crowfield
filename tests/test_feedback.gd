extends TestCase


func test_death_feedback_only_describes_the_own_soldier() -> void:
	var feedback := Feedback.new()
	var death := Messages.Death.new()
	death.killer = 7
	death.victim = 11
	death.killer_name = "Grackle"
	death.weapon = WeaponTuning.Kind.ASSAULT_RIFLE
	death.zone = Hitboxes.Zone.HEAD
	feedback.take([death], 7, null)
	check_equal(feedback.killed_by, "", "a kill does not change the death screen")
	feedback.take([death], 11, null)
	check_equal(feedback.killed_by, "Killed by Grackle with the assault rifle, in the head", "own death is still explained")
	var other := Messages.Death.new()
	other.victim = 12
	feedback.take([other], 11, null)
	check_equal(feedback.killed_by, "Killed by Grackle with the assault rifle, in the head", "another death cannot overwrite it")
