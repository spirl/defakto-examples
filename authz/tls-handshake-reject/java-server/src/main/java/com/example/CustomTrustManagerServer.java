package com.example;

import java.net.Socket;
import java.nio.file.Path;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.regex.Pattern;

import javax.net.ssl.KeyManager;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509ExtendedTrustManager;

/**
 * Java server — "custom" variation.
 *
 * This variation hand-rolls the SPIFFE-ID authorization using only the JSSE
 * standard library. The pattern (from the reference notes) is:
 *
 *   1. Wrap the platform's normal X509ExtendedTrustManager (built here from a
 *      trust store containing our demo CA) so that standard chain / expiry /
 *      trust-bundle validation still happens.
 *   2. Add our own SAN check on top: the client leaf's URI SAN must match the
 *      allowed SPIFFE pattern. Throwing CertificateException aborts the TLS
 *      handshake.
 *
 * Compare with SpiffeLibServer, which gets the same result from the java-spiffe
 * library instead of this hand-written trust manager.
 *
 * Rejection point: the TLS handshake.
 *
 * Run:  java -cp target/java-server.jar com.example.CustomTrustManagerServer   # :8446
 */
public class CustomTrustManagerServer {

    private static final String TAG = "java-custom";
    private static final int PORT = 8446;

    public static void main(String[] args) throws Exception {
        Path certs = Path.of(System.getProperty("certsDir", "certs"));

        // Build the delegate trust manager from a trust store holding our CA.
        // This delegate performs the normal chain validation we must NOT skip.
        TrustManagerFactory tmf = TrustManagerFactory.getInstance("PKIX");
        tmf.init(PemUtils.trustStoreFromCa(certs.resolve("ca.crt")));
        X509ExtendedTrustManager delegate = null;
        for (TrustManager tm : tmf.getTrustManagers()) {
            if (tm instanceof X509ExtendedTrustManager x) {
                delegate = x;
                break;
            }
        }
        if (delegate == null) throw new IllegalStateException("no X509ExtendedTrustManager available");

        KeyManager[] kms = PemUtils.serverKeyManagers(certs.resolve("server.crt"), certs.resolve("server.key"));

        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(kms, new TrustManager[]{ new SanCheckingTrustManager(delegate) }, null);

        HttpServerRunner.log(TAG, "authorization rule (regex): " + Rule.ALLOWED_URI_REGEX);
        HttpServerRunner.start(PORT, ctx, TAG);
    }

    /**
     * Delegates standard validation to the platform trust manager, then adds a
     * SPIFFE-ID SAN pattern check.
     */
    static final class SanCheckingTrustManager extends X509ExtendedTrustManager {
        private final X509ExtendedTrustManager delegate;
        private final Pattern allowed = Pattern.compile(Rule.ALLOWED_URI_REGEX);

        SanCheckingTrustManager(X509ExtendedTrustManager delegate) {
            this.delegate = delegate;
        }

        // --- client-auth overloads: validate chain, then enforce the SAN. ---

        @Override
        public void checkClientTrusted(X509Certificate[] chain, String authType, Socket socket)
                throws CertificateException {
            delegate.checkClientTrusted(chain, authType, socket);
            checkSan(chain[0]);
        }

        @Override
        public void checkClientTrusted(X509Certificate[] chain, String authType, SSLEngine engine)
                throws CertificateException {
            delegate.checkClientTrusted(chain, authType, engine);
            checkSan(chain[0]);
        }

        @Override
        public void checkClientTrusted(X509Certificate[] chain, String authType)
                throws CertificateException {
            delegate.checkClientTrusted(chain, authType);
            checkSan(chain[0]);
        }

        private void checkSan(X509Certificate leaf) throws CertificateException {
            String clientId;
            try {
                clientId = PemUtils.uriSan(leaf);
            } catch (Exception e) {
                throw new CertificateException("could not read client URI SAN", e);
            }
            if (clientId != null && allowed.matcher(clientId).matches()) {
                HttpServerRunner.log(TAG, "ALLOW handshake: client SPIFFE ID \"" + clientId
                        + "\" matches " + Rule.ALLOWED_URI_REGEX);
                return;
            }
            // Server-side observability: the exact reason is logged here, even
            // though the client will only see an opaque TLS handshake failure.
            HttpServerRunner.log(TAG, "DENY handshake: client SPIFFE ID \"" + clientId
                    + "\" does NOT match required pattern " + Rule.ALLOWED_URI_REGEX);
            throw new CertificateException("client SPIFFE ID \"" + clientId + "\" not authorized");
        }

        // --- server-auth + issuers: delegate straight through. ---

        @Override
        public void checkServerTrusted(X509Certificate[] chain, String authType, Socket socket)
                throws CertificateException {
            delegate.checkServerTrusted(chain, authType, socket);
        }

        @Override
        public void checkServerTrusted(X509Certificate[] chain, String authType, SSLEngine engine)
                throws CertificateException {
            delegate.checkServerTrusted(chain, authType, engine);
        }

        @Override
        public void checkServerTrusted(X509Certificate[] chain, String authType)
                throws CertificateException {
            delegate.checkServerTrusted(chain, authType);
        }

        @Override
        public X509Certificate[] getAcceptedIssuers() {
            return delegate.getAcceptedIssuers();
        }
    }
}
