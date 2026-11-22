extends TestCase


func test_kill_feed_keeps_personal_outcomes_through_a_busy_exchange() -> void:
	var feedback := Feedback.new()
	var own := Messages.Death.new()
	own.killer = 7
	own.victim = 11
	own.victim_name = "Local opponent"
	feedback.take([own], 7, null)
	for index in 12:
		var other := Messages.Death.new()
		other.killer = 8
		other.victim = 12
		other.victim_name = "Bot %d" % index
		feedback.take([other], 7, null)
	check_equal(feedback.feed.size(), Feedback.FEED_LENGTH, "feed stays compact under load")
	check_equal(feedback.feed[0].victim, "Local opponent", "background reports cannot evict the player outcome")
	check_equal(feedback.feed[-1].victim, "Bot 11", "new background reports replace older ones")
	feedback.update(Feedback.FEED_TIME)
	check_equal(feedback.feed.size(), 1, "background reports expire first")
	feedback.update(Feedback.OWN_FEED_TIME)
	check(feedback.feed.is_empty(), "the personal outcome expires")
