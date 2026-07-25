package com.example;

import java.nio.file.Path;

import javax.net.ssl.KeyManager;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;

import io.spiffe.bundle.x509bundle.X509Bundle;
import io.spiffe.provider.SpiffeTrustManager;
import io.spiffe.provider.SpiffeVerificationException;
import io.spiffe.spiffeid.TrustDomain;

/**
 * Java server — "config-based" / library variation.
 *
 * This variation uses the official java-spiffe library
 * (io.spiffe:java-spiffe-provider) instead of a hand-written trust manager.
 * The library provides:
 *
 *   - X509Bundle: loads the trust bundle (CA) for a trust domain.
 *   - SpiffeTrustManager: an X509ExtendedTrustManager that validates the peer
 *     against the bundle AND parses its URI SAN into a SpiffeId, then hands
 *     that SpiffeId to a SpiffeIdVerifier for the allow/deny decision.
 *
 * We supply a SpiffeIdVerifier lambda implementing the "path must start with
 * /ns/prod/" rule. NOTE: java-spiffe can also verify against an exact accepted
 * SpiffeId set, but a verifier lets us match on a PATTERN within the trust
 * domain — which is the whole point of this demo.
 *
 * (In production the X509Bundle and the server's key material would come from
 * the SPIFFE Workload API and auto-rotate; here we load them from PEM files so
 * the demo has no runtime dependencies.)
 *
 * Rejection point: the TLS handshake (same as the custom variation).
 *
 * Run:  java -cp target/java-server.jar com.example.SpiffeLibServer   # :8445
 */
public class SpiffeLibServer {

    private static final String TAG = "java-spiffe";
    private static final int PORT = 8445;

    public static void main(String[] args) throws Exception {
        Path certs = Path.of(System.getProperty("certsDir", "certs"));

        TrustDomain td = TrustDomain.parse(Rule.TRUST_DOMAIN);
        X509Bundle bundle = X509Bundle.load(td, certs.resolve("ca.crt"));

        // THE CHECK, as a structured verifier over the parsed SpiffeId. The
        // library has already validated the chain against the bundle and parsed
        // the URI SAN before this runs.
        SpiffeTrustManager tm = new SpiffeTrustManager(bundle, (spiffeId, chain) -> {
            String id = spiffeId.toString();
            if (!spiffeId.getPath().startsWith(Rule.ALLOWED_PATH_PREFIX)) {
                // Server-side observability record of the exact reason.
                HttpServerRunner.log(TAG, "DENY handshake: client SPIFFE ID \"" + id
                        + "\" path \"" + spiffeId.getPath() + "\" does NOT start with \""
                        + Rule.ALLOWED_PATH_PREFIX + "\"");
                throw new SpiffeVerificationException("SPIFFE ID \"" + id
                        + "\" not authorized (path must start with " + Rule.ALLOWED_PATH_PREFIX + ")");
            }
            HttpServerRunner.log(TAG, "ALLOW handshake: client SPIFFE ID \"" + id
                    + "\" matches path prefix \"" + Rule.ALLOWED_PATH_PREFIX + "\"");
        });

        KeyManager[] kms = PemUtils.serverKeyManagers(certs.resolve("server.crt"), certs.resolve("server.key"));

        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(kms, new TrustManager[]{ tm }, null);

        HttpServerRunner.log(TAG, "authorization rule: SPIFFE path must start with \""
                + Rule.ALLOWED_PATH_PREFIX + "\" (trust domain " + Rule.TRUST_DOMAIN + ")");
        HttpServerRunner.start(PORT, ctx, TAG);
    }
}
