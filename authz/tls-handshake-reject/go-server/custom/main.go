// Go server — "custom" variation.
//
// This variation does the SPIFFE-ID authorization by hand, using only the Go
// standard library (crypto/tls, crypto/x509). It is the most explicit way to
// see exactly where and how the rejection happens: inside the
// tls.Config.VerifyPeerCertificate hook, which runs AFTER Go has already
// verified the client's certificate chain against our CA.
//
// Compare with ../config-based, which achieves the identical result using the
// go-spiffe library's authorizer helpers instead of hand-written code.
//
// Rejection point: the TLS handshake. Returning a non-nil error from
// VerifyPeerCertificate aborts the handshake, so the client never gets an HTTP
// response — only a transport-level error.
//
// Usage:
//
//	go run ./go-server/custom            # listens on :8444
package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/spirl/tls-handshake-reject/common/spiffeid"
)

const defaultAddr = "localhost:8444"

func main() {
	addr := defaultAddr
	if v := os.Getenv("ADDR"); v != "" {
		addr = v
	}

	logger := log.New(os.Stdout, "[go-custom] ", log.LstdFlags|log.Lmicroseconds)

	serverCert, err := tls.LoadX509KeyPair("certs/server.crt", "certs/server.key")
	if err != nil {
		logger.Fatalf("load server cert: %v", err)
	}
	caPEM, err := os.ReadFile("certs/ca.crt")
	if err != nil {
		logger.Fatalf("read CA: %v", err)
	}
	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caPEM) {
		logger.Fatalf("parse CA cert")
	}

	tlsConf := &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		// RequireAndVerifyClientCert => Go verifies the client cert chains to
		// our CA (rejecting untrusted/expired certs) BEFORE our hook runs.
		ClientAuth: tls.RequireAndVerifyClientCert,
		ClientCAs:  caPool,

		// This hook is our authorization layer. It runs after standard chain
		// verification succeeds. verifiedChains[0][0] is the client leaf.
		VerifyPeerCertificate: func(_ [][]byte, verifiedChains [][]*x509.Certificate) error {
			if len(verifiedChains) == 0 || len(verifiedChains[0]) == 0 {
				return fmt.Errorf("no verified client chain")
			}
			leaf := verifiedChains[0][0]

			// Pull the SPIFFE ID out of the URI SAN.
			if len(leaf.URIs) == 0 {
				logger.Printf("DENY handshake: client presented a cert with no URI SAN (no SPIFFE ID)")
				return fmt.Errorf("client certificate has no URI SAN")
			}
			clientID := leaf.URIs[0].String()

			// THE CHECK: match the raw SPIFFE URI against the allowed regex.
			// (The regex form of the rule; see common/spiffeid for how to
			// change it to a suffix or any other pattern.)
			if spiffeid.AllowedURIRegex.MatchString(clientID) {
				logger.Printf("ALLOW handshake: client SPIFFE ID %q matches %s", clientID, spiffeid.AllowedURIRegex)
				return nil
			}

			// This log line is the whole point of the observability story:
			// the operator sees precisely why the connection was refused,
			// even though the client will only see an opaque TLS error.
			logger.Printf("DENY handshake: client SPIFFE ID %q does NOT match required pattern %s",
				clientID, spiffeid.AllowedURIRegex)
			return fmt.Errorf("client SPIFFE ID %q not authorized", clientID)
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// We only reach here if the handshake (and thus authz) succeeded.
		clientID := "<none>"
		if len(r.TLS.PeerCertificates) > 0 && len(r.TLS.PeerCertificates[0].URIs) > 0 {
			clientID = r.TLS.PeerCertificates[0].URIs[0].String()
		}
		logger.Printf("serving request for authorized client %s", clientID)
		fmt.Fprintf(w, "hello, authorized client %s\n", clientID)
	})

	srv := &http.Server{
		Addr:      addr,
		Handler:   mux,
		TLSConfig: tlsConf,
		ErrorLog:  logger, // surfaces handshake errors on the server side
		ReadTimeout: 10 * time.Second,
	}

	logger.Printf("listening on https://%s", addr)
	logger.Printf("authorization rule (regex): %s", spiffeid.AllowedURIRegex)
	// Certs are already in TLSConfig, so pass empty paths.
	if err := srv.ListenAndServeTLS("", ""); err != nil {
		logger.Fatalf("server stopped: %v", err)
	}
}
