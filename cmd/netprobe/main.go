package main

import (
	"context"
	"flag"
	"log"
	"time"

	"ravenfield/internal/network"
)

func main() {
	delay := flag.Duration("delay", 20*time.Millisecond, "one-way delay for each UDP packet")
	dropEvery := flag.Uint64("drop-every", 10, "drop every Nth UDP packet in each direction")
	timeout := flag.Duration("timeout", 15*time.Second, "probe timeout")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	result, err := network.RunProbe(ctx, *delay, *dropEvery)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("QUIC probe passed: stream_rtt=%s datagram_rtt=%s dropped_packets=%d", result.StreamRTT, result.DatagramRTT, result.Dropped)
}
