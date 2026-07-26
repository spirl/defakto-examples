// Package spiffeid is the single source of truth for the demo's identities
// and the authorization rule that every server variation enforces.
//
// The whole point of this demo is to reject an mTLS peer based on a pattern
// *within* the SPIFFE ID path — NOT based on the trust domain. Every identity
// below lives in the same trust domain ("example.org"), so the trust bundle
// (CA) validates all of them. The rejection happens purely because the peer's
// SPIFFE ID path does not match the required pattern.
package spiffeid

import "regexp"

// The identities used by the demo. They follow a common SPIFFE path convention:
//
//	spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
//
// Note that ClientDenied is in the SAME trust domain as everything else. It is
// a perfectly valid, CA-signed identity. It is rejected only because its path
// is in the "dev" namespace instead of "prod".
const (
	TrustDomain = "example.org"

	ServerID        = "spiffe://example.org/ns/prod/sa/server"   // the server's own identity
	ClientAllowedID = "spiffe://example.org/ns/prod/sa/frontend" // prod namespace  -> ACCEPTED
	ClientDeniedID  = "spiffe://example.org/ns/dev/sa/frontend"  // dev namespace   -> REJECTED
)

// ---------------------------------------------------------------------------
// THE AUTHORIZATION RULE
// ---------------------------------------------------------------------------
//
// Rule in plain English: "Only admit callers in the prod namespace."
//
// We express the exact same rule two ways, because the server variations
// in this repo demonstrate two authoring styles:
//
//   - Structured style (AllowedPathPrefix): parse the peer's SPIFFE ID and
//     compare its trust domain + path against structured fields. Used by the
//     go-spiffe and java-spiffe "library" variations.
//
//   - Regex style (AllowedURIRegex): match the raw URI SAN string against a
//     regular expression. Used by the Go "custom" variation and by Envoy's
//     static match_typed_subject_alt_names config.
//
// Both forms accept ClientAllowedID and reject ClientDeniedID identically.
const (
	// AllowedPathPrefix is the structured form of the rule: the peer's SPIFFE
	// ID path must begin with this prefix (and be in TrustDomain).
	AllowedPathPrefix = "/ns/prod/"
)

// AllowedURIRegex is the regex form of the same rule, anchored to the full
// SPIFFE URI. Envoy's static config uses an equivalent regex string.
//
// HOW TO ENFORCE A DIFFERENT PATTERN
// ----------------------------------
// This demo enforces a namespace *prefix*. The same mechanism enforces any
// other shape of rule — you only change this pattern (and AllowedPathPrefix):
//
//	Suffix (specific service account):
//	    ^spiffe://example\.org/ns/[^/]+/sa/frontend$
//
//	A set of allowed namespaces:
//	    ^spiffe://example\.org/ns/(prod|staging)/.*$
//
//	An arbitrary interior segment (e.g. a region):
//	    ^spiffe://example\.org/.*/region/us-east-1/.*$
//
// The enforcement code never changes — only the pattern does.
var AllowedURIRegex = regexp.MustCompile(`^spiffe://example\.org/ns/prod/.*$`)
