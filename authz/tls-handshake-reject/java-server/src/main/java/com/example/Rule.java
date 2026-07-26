package com.example;

/**
 * The authorization rule and identities, mirrored from
 * ../../common/spiffeid/spiffeid.go so the Java servers enforce exactly the
 * same policy as the Go and Envoy examples.
 *
 * The whole point of the demo: reject based on a pattern WITHIN the trust
 * domain (the path), not on the trust domain itself. Every identity below is
 * in trust domain "example.org".
 */
public final class Rule {
    private Rule() {}

    public static final String TRUST_DOMAIN = "example.org";

    public static final String SERVER_ID         = "spiffe://example.org/ns/prod/sa/server";
    public static final String CLIENT_ALLOWED_ID = "spiffe://example.org/ns/prod/sa/frontend"; // ACCEPTED
    public static final String CLIENT_DENIED_ID  = "spiffe://example.org/ns/dev/sa/frontend";  // REJECTED

    /**
     * The rule, structured form: the peer's SPIFFE ID path must start with
     * this prefix. ("prod" namespace only.)
     */
    public static final String ALLOWED_PATH_PREFIX = "/ns/prod/";

    /**
     * The rule, regex form (over the full SPIFFE URI). Equivalent to the
     * prefix above; used by the hand-rolled trust manager to show the
     * regex/pattern style.
     *
     * To enforce a different shape of rule, change only this pattern, e.g.:
     *   suffix (specific SA):        ^spiffe://example\.org/ns/[^/]+/sa/frontend$
     *   a set of namespaces:         ^spiffe://example\.org/ns/(prod|staging)/.*$
     */
    public static final String ALLOWED_URI_REGEX = "^spiffe://example\\.org/ns/prod/.*$";
}
