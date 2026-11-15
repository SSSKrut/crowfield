package network

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
)

type ProbeResult struct {
	StreamRTT   time.Duration
	DatagramRTT time.Duration
	Dropped     uint64
}

type lossyPacketConn struct {
	net.PacketConn
	delay     time.Duration
	dropEvery uint64
	writes    uint64
	dropped   uint64
}

func (c *lossyPacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	write := atomic.AddUint64(&c.writes, 1)
	if c.dropEvery > 0 && write%c.dropEvery == 0 {
		atomic.AddUint64(&c.dropped, 1)
		return len(p), nil
	}
	if c.delay > 0 {
		time.Sleep(c.delay)
	}
	return c.PacketConn.WriteTo(p, addr)
}

func (c *lossyPacketConn) SetReadBuffer(bytes int) error {
	return c.PacketConn.(*net.UDPConn).SetReadBuffer(bytes)
}

func (c *lossyPacketConn) SetWriteBuffer(bytes int) error {
	return c.PacketConn.(*net.UDPConn).SetWriteBuffer(bytes)
}

func RunProbe(ctx context.Context, delay time.Duration, dropEvery uint64) (ProbeResult, error) {
	serverTLS, err := probeServerTLS()
	if err != nil {
		return ProbeResult{}, err
	}
	clientTLS := &tls.Config{
		NextProtos: []string{"ravenfield-probe"},
		// The probe uses a generated in-memory certificate, not a public identity.
		InsecureSkipVerify: true,
	}
	quicConfig := &quic.Config{
		EnableDatagrams:      true,
		HandshakeIdleTimeout: 5 * time.Second,
		MaxIdleTimeout:       10 * time.Second,
	}
	serverUDP, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		return ProbeResult{}, err
	}
	defer serverUDP.Close()
	serverConn := &lossyPacketConn{PacketConn: serverUDP, delay: delay, dropEvery: dropEvery}
	listener, err := quic.Listen(serverConn, serverTLS, quicConfig)
	if err != nil {
		return ProbeResult{}, err
	}
	defer listener.Close()

	serverError := make(chan error, 1)
	clientDone := make(chan struct{})
	go func() {
		conn, err := listener.Accept(ctx)
		if err != nil {
			serverError <- err
			return
		}
		defer conn.CloseWithError(0, "probe complete")
		stream, err := conn.AcceptStream(ctx)
		if err != nil {
			serverError <- err
			return
		}
		defer stream.Close()
		payload := make([]byte, 4)
		if _, err := io.ReadFull(stream, payload); err != nil {
			serverError <- err
			return
		}
		if string(payload) != "PING" {
			serverError <- fmt.Errorf("unexpected stream payload %q", payload)
			return
		}
		if _, err := stream.Write([]byte("PONG")); err != nil {
			serverError <- err
			return
		}
		if err := conn.SendDatagram([]byte("SNAPSHOT")); err != nil {
			serverError <- err
			return
		}
		<-clientDone
		serverError <- nil
	}()

	clientUDP, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		return ProbeResult{}, err
	}
	defer clientUDP.Close()
	clientConn := &lossyPacketConn{PacketConn: clientUDP, delay: delay, dropEvery: dropEvery}
	conn, err := quic.Dial(ctx, clientConn, serverUDP.LocalAddr(), clientTLS, quicConfig)
	if err != nil {
		return ProbeResult{}, err
	}
	defer conn.CloseWithError(0, "probe complete")
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return ProbeResult{}, err
	}
	defer stream.Close()
	started := time.Now()
	if _, err := stream.Write([]byte("PING")); err != nil {
		return ProbeResult{}, err
	}
	payload := make([]byte, 4)
	if _, err := io.ReadFull(stream, payload); err != nil {
		return ProbeResult{}, err
	}
	streamRTT := time.Since(started)
	if string(payload) != "PONG" {
		return ProbeResult{}, fmt.Errorf("unexpected stream response %q", payload)
	}
	datagramStarted := time.Now()
	datagram, err := conn.ReceiveDatagram(ctx)
	if err != nil {
		return ProbeResult{}, err
	}
	if string(datagram) != "SNAPSHOT" {
		return ProbeResult{}, fmt.Errorf("unexpected datagram %q", datagram)
	}
	close(clientDone)
	if err := <-serverError; err != nil {
		return ProbeResult{}, err
	}
	return ProbeResult{
		StreamRTT: streamRTT, DatagramRTT: time.Since(datagramStarted),
		Dropped: atomic.LoadUint64(&serverConn.dropped) + atomic.LoadUint64(&clientConn.dropped),
	}, nil
}

func probeServerTLS() (*tls.Config, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "ravenfield-probe"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	certificate, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	keyPEM, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, err
	}
	pair, err := tls.X509KeyPair(
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate}),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyPEM}),
	)
	if err != nil {
		return nil, err
	}
	return &tls.Config{Certificates: []tls.Certificate{pair}, NextProtos: []string{"ravenfield-probe"}}, nil
}
