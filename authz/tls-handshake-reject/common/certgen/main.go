// Command certgen creates the identity material used by every example in this
// repo: a self-signed CA (the "trust bundle") and three leaf certificates that
// carry a spiffe:// URI in their Subject Alternative Name.
//
// This stands in for a real SPIFFE deployment. In production your SPIFFE
// implementation would issue these SVIDs; here we mint them directly so the demo
// has zero runtime dependencies. What matters for the demo — a CA-signed leaf
// whose URI SAN is a SPIFFE ID — is identical either way.
//
// Everything is written as PEM into ./certs so that Go, Java (via a small PEM
// loader), and Envoy can all consume the exact same files.
//
// Usage:
//
//	go run ./common/certgen              # writes into ./certs
//	go run ./common/certgen -out /path   # custom output dir
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/spirl/tls-handshake-reject/common/spiffeid"
)

func main() {
	outDir := flag.String("out", "certs", "directory to write PEM files into")
	flag.Parse()

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		log.Fatalf("create out dir: %v", err)
	}

	// 1. Create the CA (the SPIFFE trust bundle for trust domain example.org).
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatalf("generate CA key: %v", err)
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          serial(),
		Subject:               pkix.Name{CommonName: "tls-handshake-reject demo CA (" + spiffeid.TrustDomain + ")"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		log.Fatalf("create CA cert: %v", err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		log.Fatalf("parse CA cert: %v", err)
	}
	writePEM(*outDir, "ca.crt", "CERTIFICATE", caDER)
	writeKey(*outDir, "ca.key", caKey)

	// 2. Mint the leaf SVIDs. Each gets its SPIFFE ID as a URI SAN.
	leaves := []struct {
		name     string
		spiffeID string
	}{
		{"server", spiffeid.ServerID},
		{"client-allowed", spiffeid.ClientAllowedID},
		{"client-denied", spiffeid.ClientDeniedID},
	}
	for _, l := range leaves {
		mintLeaf(*outDir, l.name, l.spiffeID, caCert, caKey)
	}

	fmt.Printf("Wrote CA + %d leaf SVIDs to %s/\n", len(leaves), *outDir)
	fmt.Println("Identities:")
	fmt.Printf("  server         %s\n", spiffeid.ServerID)
	fmt.Printf("  client-allowed %s   (prod namespace -> will be ACCEPTED)\n", spiffeid.ClientAllowedID)
	fmt.Printf("  client-denied  %s    (dev namespace  -> will be REJECTED)\n", spiffeid.ClientDeniedID)
}

func mintLeaf(dir, name, spiffeID string, caCert *x509.Certificate, caKey *ecdsa.PrivateKey) {
	uri, err := url.Parse(spiffeID)
	if err != nil {
		log.Fatalf("parse spiffe id %q: %v", spiffeID, err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatalf("generate key for %s: %v", name, err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial(),
		// SPIFFE leaf certs intentionally carry no meaningful Subject; identity
		// lives entirely in the URI SAN below.
		Subject:     pkix.Name{CommonName: name},
		NotBefore:   time.Now().Add(-time.Hour),
		NotAfter:    time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		URIs:        []*url.URL{uri}, // <-- the SPIFFE ID goes here
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		log.Fatalf("create cert for %s: %v", name, err)
	}
	writePEM(dir, name+".crt", "CERTIFICATE", der)
	writeKey(dir, name+".key", key)
}

func serial() *big.Int {
	max := new(big.Int).Lsh(big.NewInt(1), 128)
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		log.Fatalf("serial: %v", err)
	}
	return n
}

func writePEM(dir, file, blockType string, der []byte) {
	path := filepath.Join(dir, file)
	f, err := os.Create(path)
	if err != nil {
		log.Fatalf("create %s: %v", path, err)
	}
	defer f.Close()
	if err := pem.Encode(f, &pem.Block{Type: blockType, Bytes: der}); err != nil {
		log.Fatalf("encode %s: %v", path, err)
	}
}

// writeKey writes an EC private key in PKCS#8 PEM form. PKCS#8 is used (rather
// than SEC1 "EC PRIVATE KEY") because Java's PKCS8EncodedKeySpec reads it
// directly, letting all three ecosystems share one key file format.
func writeKey(dir, file string, key *ecdsa.PrivateKey) {
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		log.Fatalf("marshal key: %v", err)
	}
	path := filepath.Join(dir, file)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		log.Fatalf("create %s: %v", path, err)
	}
	defer f.Close()
	if err := pem.Encode(f, &pem.Block{Type: "PRIVATE KEY", Bytes: der}); err != nil {
		log.Fatalf("encode %s: %v", path, err)
	}
}
