// Go server — "config-based" / library variation.
//
// This variation uses the official go-spiffe library
// (github.com/spiffe/go-spiffe/v2) instead of hand-rolled crypto/x509 code.
// The library gives you:
//
//   - x509svid / x509bundle sources that load the server's SVID and the trust
//     bundle (here from files; in production these come from the SPIFFE
//     Workload API and auto-rotate).
//   - tlsconfig.MTLSServerConfig, which builds a *tls.Config wired for mTLS.
//   - an "authorizer" that expresses the allow/deny decision against a parsed
//     spiffeid.ID rather than raw certificate bytes.
//
// We use tlsconfig.AdaptMatcher to supply our own matcher. NOTE: the library
// also ships tlsconfig.AuthorizeMemberOf(trustDomain), but that only checks the
// TRUST DOMAIN — which is explicitly NOT what this demo is about. To reject on
// a pattern *within* the trust domain we match on the ID's path instead.
//
// Rejection point: the TLS handshake (same as the custom variation).
//
// Usage:
//
//	go run ./go-server/config-based      # listens on :8443
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	gospiffeid "github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/bundle/x509bundle"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"

	"github.com/spirl/tls-handshake-reject/common/spiffeid"
)

const defaultAddr = "localhost:8443"

func main() {
	addr := defaultAddr
	if v := os.Getenv("ADDR"); v != "" {
		addr = v
	}

	logger := log.New(os.Stdout, "[go-spiffe] ", log.LstdFlags|log.Lmicroseconds)

	td := gospiffeid.RequireTrustDomainFromString(spiffeid.TrustDomain)

	// Load the server's SVID (cert+key) and the trust bundle (CA) from the
	// generated PEM files. A production workload would obtain these from the
	// SPIFFE Workload API via workloadapi.X509Source instead.
	svid, err := x509svid.Load("certs/server.crt", "certs/server.key")
	if err != nil {
		logger.Fatalf("load server SVID: %v", err)
	}
	bundle, err := x509bundle.Load(td, "certs/ca.crt")
	if err != nil {
		logger.Fatalf("load trust bundle: %v", err)
	}

	// THE CHECK, expressed as a structured matcher over the parsed SPIFFE ID.
	// The library has already: verified the chain against the bundle AND
	// parsed the URI SAN into a valid spiffeid.ID before calling us.
	matcher := func(id gospiffeid.ID) error {
		if id.TrustDomain() != td {
			// Defense in depth; the bundle already enforces trust domain.
			logger.Printf("DENY handshake: %q is in a different trust domain", id)
			return fmt.Errorf("unexpected trust domain %q", id.TrustDomain())
		}
		// The pattern-within-trust-domain rule: path must start with /ns/prod/.
		// (See common/spiffeid for how to express a suffix or other pattern.)
		if !strings.HasPrefix(id.Path(), spiffeid.AllowedPathPrefix) {
			logger.Printf("DENY handshake: client SPIFFE ID %q path %q does NOT start with %q",
				id, id.Path(), spiffeid.AllowedPathPrefix)
			return fmt.Errorf("SPIFFE ID %q not authorized (path must start with %q)", id, spiffeid.AllowedPathPrefix)
		}
		logger.Printf("ALLOW handshake: client SPIFFE ID %q matches path prefix %q", id, spiffeid.AllowedPathPrefix)
		return nil
	}

	tlsConf := tlsconfig.MTLSServerConfig(svid, bundle, tlsconfig.AdaptMatcher(matcher))

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		clientID := "<none>"
		if len(r.TLS.PeerCertificates) > 0 && len(r.TLS.PeerCertificates[0].URIs) > 0 {
			clientID = r.TLS.PeerCertificates[0].URIs[0].String()
		}
		logger.Printf("serving request for authorized client %s", clientID)
		fmt.Fprintf(w, "hello, authorized client %s\n", clientID)
	})

	srv := &http.Server{
		Addr:        addr,
		Handler:     mux,
		TLSConfig:   tlsConf,
		ErrorLog:    logger, // surfaces handshake errors on the server side
		ReadTimeout: 10 * time.Second,
	}

	logger.Printf("listening on https://%s", addr)
	logger.Printf("authorization rule: SPIFFE path must start with %q (trust domain %s)", spiffeid.AllowedPathPrefix, spiffeid.TrustDomain)
	if err := srv.ListenAndServeTLS("", ""); err != nil {
		logger.Fatalf("server stopped: %v", err)
	}
}
