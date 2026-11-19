package transport

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"io/fs"
	"math/big"
	"os"
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

// LoadOrCreateCertificate reads the server certificate from two PEM files, or
// creates and stores one on the first run, so its fingerprint stays the same.
func LoadOrCreateCertificate(certificatePath, keyPath string) (tls.Certificate, Fingerprint, error) {
	certificate, err := tls.LoadX509KeyPair(certificatePath, keyPath)
	if err == nil {
		return certificate, sha256.Sum256(certificate.Certificate[0]), nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return tls.Certificate{}, Fingerprint{}, err
	}
	certificate, fingerprint, err := GenerateCertificate()
	if err != nil {
		return tls.Certificate{}, Fingerprint{}, err
	}
	key, err := x509.MarshalPKCS8PrivateKey(certificate.PrivateKey)
	if err != nil {
		return tls.Certificate{}, Fingerprint{}, err
	}
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Certificate[0]})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return tls.Certificate{}, Fingerprint{}, err
	}
	if err := os.WriteFile(certificatePath, certificatePEM, 0o644); err != nil {
		return tls.Certificate{}, Fingerprint{}, err
	}
	return certificate, fingerprint, nil
}

func (f Fingerprint) String() string {
	return hex.EncodeToString(f[:])
}

func ParseFingerprint(text string) (Fingerprint, error) {
	var fingerprint Fingerprint
	decoded, err := hex.DecodeString(text)
	if err != nil || len(decoded) != len(fingerprint) {
		return fingerprint, fmt.Errorf("fingerprint must be %d hex digits", 2*len(fingerprint))
	}
	copy(fingerprint[:], decoded)
	return fingerprint, nil
}

// PeerFingerprint returns the fingerprint of the server a QUIC connection
// reached, so a client can show it and pin it next time.
func PeerFingerprint(conn Conn) (Fingerprint, bool) {
	c, ok := conn.(*quicConn)
	if !ok {
		return Fingerprint{}, false
	}
	certificates := c.conn.ConnectionState().TLS.PeerCertificates
	if len(certificates) == 0 {
		return Fingerprint{}, false
	}
	return sha256.Sum256(certificates[0].Raw), true
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
