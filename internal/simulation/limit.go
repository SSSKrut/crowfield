package simulation

import "time"

// rateLimit is a token bucket: rate tokens a second, at most burst kept.
type rateLimit struct {
	rate, burst float64
	tokens      float64
	last        time.Time
}

func newRateLimit(rate, burst float64) rateLimit {
	return rateLimit{rate: rate, burst: burst, tokens: burst}
}

// allow takes a token if one is left at the time now.
func (l *rateLimit) allow(now time.Time) bool {
	if !l.last.IsZero() {
		l.tokens = min(l.burst, l.tokens+now.Sub(l.last).Seconds()*l.rate)
	}
	l.last = now
	if l.tokens < 1 {
		return false
	}
	l.tokens--
	return true
}
