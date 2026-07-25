// Command client is the single mTLS client used against every server variation
// in this repo (Go, Java, and Envoy). It presents either the "allowed" (prod)
// or the "denied" (dev) client SVID and makes one HTTPS GET request.
//
// Its main job is to show what a caller *actually experiences* when a server
// rejects it for having the wrong SPIFFE ID. Every server in this demo rejects
// during the TLS handshake, so the client does NOT get a nice "403 Forbidden":
// it gets an opaque TLS/connection error like "remote error: tls: bad
// certificate" or a broken pipe. This is the key operational gotcha the demo
// highlights — the real reason lives in the SERVER logs, not on the client.
//
// (The client still handles a normal HTTP response too, so it works unchanged
// if you move the authorization check up to L7; see the README's "Important
// considerations" section.)
//
// Usage:
//
//	go run ./common/client -addr localhost:8443 -id allowed
//	go run ./common/client -addr localhost:8443 -id denied
package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/spirl/tls-handshake-reject/common/spiffeid"
)

func main() {
	addr := flag.String("addr", "localhost:8443", "host:port of the server to call")
	id := flag.String("id", "allowed", `which client identity to present: "allowed" (prod) or "denied" (dev)`)
	certDir := flag.String("certs", "certs", "directory containing the generated certs")
	flag.Parse()

	var certFile, keyFile, spiffeID string
	switch *id {
	case "allowed":
		certFile, keyFile, spiffeID = "client-allowed.crt", "client-allowed.key", spiffeid.ClientAllowedID
	case "denied":
		certFile, keyFile, spiffeID = "client-denied.crt", "client-denied.key", spiffeid.ClientDeniedID
	default:
		log.Fatalf(`-id must be "allowed" or "denied", got %q`, *id)
	}

	clientCert, err := tls.LoadX509KeyPair(*certDir+"/"+certFile, *certDir+"/"+keyFile)
	if err != nil {
		log.Fatalf("load client cert: %v", err)
	}
	caPEM, err := os.ReadFile(*certDir + "/ca.crt")
	if err != nil {
		log.Fatalf("read CA: %v", err)
	}
	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caPEM) {
		log.Fatalf("failed to parse CA cert")
	}

	fmt.Printf("→ Calling https://%s as %q\n", *addr, spiffeID)

	tlsConf := &tls.Config{
		Certificates: []tls.Certificate{clientCert},
		// SPIFFE certs identify by URI SAN, not DNS name, so the default
		// hostname check would fail. We disable it and instead verify the
		// server ourselves: valid chain to our CA + expected server SPIFFE ID.
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: verifyServerSpiffeID(caPool, spiffeid.ServerID),
	}

	httpClient := &http.Client{
		Timeout:   10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: tlsConf},
	}

	resp, err := httpClient.Get("https://" + *addr + "/")
	if err != nil {
		fmt.Println("✗ Request FAILED (no HTTP response received).")
		fmt.Printf("  Go error: %v\n", err)
		explain(err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode == http.StatusOK {
		fmt.Printf("✓ Request SUCCEEDED: HTTP %s\n", resp.Status)
	} else {
		fmt.Printf("✗ Request REJECTED at the application layer: HTTP %s\n", resp.Status)
	}
	if len(body) > 0 {
		fmt.Printf("  Server said: %s\n", string(body))
	}
}

// verifyServerSpiffeID validates the server's cert chain against our CA and
// checks that its URI SAN matches the expected server SPIFFE ID.
func verifyServerSpiffeID(caPool *x509.CertPool, wantID string) func([][]byte, [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		if len(rawCerts) == 0 {
			return errors.New("server presented no certificate")
		}
		leaf, err := x509.ParseCertificate(rawCerts[0])
		if err != nil {
			return err
		}
		if _, err := leaf.Verify(x509.VerifyOptions{Roots: caPool}); err != nil {
			return fmt.Errorf("server cert not signed by demo CA: %w", err)
		}
		for _, u := range leaf.URIs {
			if u.String() == wantID {
				return nil
			}
		}
		return fmt.Errorf("server SPIFFE ID %v is not the expected %s", uriList(leaf.URIs), wantID)
	}
}

func uriList(uris []*url.URL) []string {
	out := make([]string, len(uris))
	for i, u := range uris {
		out[i] = u.String()
	}
	return out
}

// explain adds a human-readable hint about what an opaque transport error
// usually means, since this is exactly where callers get stuck.
func explain(err error) {
	msg := err.Error()
	switch {
	case contains(msg, "certificate required"), contains(msg, "bad certificate"),
		contains(msg, "certificate unknown"), contains(msg, "handshake failure"),
		contains(msg, "connection reset"), contains(msg, "EOF"), contains(msg, "broken pipe"):
		fmt.Println()
		fmt.Println("  ┌─ What this means ──────────────────────────────────────────────")
		fmt.Println("  │ The server aborted the TLS handshake. From the client side this")
		fmt.Println("  │ is deliberately opaque — TLS does not carry an authorization")
		fmt.Println("  │ reason. The actual cause (your SPIFFE ID did not match the")
		fmt.Println("  │ server's allowed pattern) is only visible in the SERVER logs.")
		fmt.Println("  │ Look there for a line naming the rejected SPIFFE ID.")
		fmt.Println("  └────────────────────────────────────────────────────────────────")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
