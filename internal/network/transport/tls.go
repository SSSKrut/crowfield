package transport

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"math/big"
	"time"
)

// alpn names the transport layout: channel streams plus datagrams. The message
// format is versioned separately, in the Hello message.
const alpn = "ravenfield/1"

// Fingerprint identifies a server certificate. Servers use self-signed
// certificates, so clients pin the fingerprint instead of checking a CA.
type Fingerprint [sha256.Size]byte

// GenerateCertificate creates a self-signed server certificate. A server should
// keep it between runs, so that clients can keep trusting its fingerprint.
func GenerateCertificate() (tls.Certificate, Fingerprint, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, Fingerprint{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return tls.Certificate{}, Fingerprint{}, err
	}
	template := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "ravenfield server"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(10, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, Fingerprint{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, sha256.Sum256(der), nil
}

func ServerTLSConfig(certificate tls.Certificate) *tls.Config {
	return &tls.Config{Certificates: []tls.Certificate{certificate}, NextProtos: []string{alpn}, MinVersion: tls.VersionTLS13}
}

var ErrUntrustedServer = errors.New("server certificate does not match the expected fingerprint")

// ClientTLSConfig trusts exactly the server with the given fingerprint. With a
// nil fingerprint it trusts any server; that is only for the first connection
// to a server, after which the client should pin what it saw.
func ClientTLSConfig(expected *Fingerprint) *tls.Config {
	return &tls.Config{
		NextProtos: []string{alpn},
		MinVersion: tls.VersionTLS13,
		// The chain is not checked against a CA; the fingerprint replaces it.
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(certificates [][]byte, _ [][]*x509.Certificate) error {
			if len(certificates) == 0 {
				return ErrUntrustedServer
			}
			if expected != nil && sha256.Sum256(certificates[0]) != *expected {
				return ErrUntrustedServer
			}
			return nil
		},
	}
}
