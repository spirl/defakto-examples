package com.example;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.List;
import java.util.ArrayList;

import javax.net.ssl.KeyManager;
import javax.net.ssl.KeyManagerFactory;

/**
 * Minimal helpers to load the PEM files produced by `go run ./common/certgen`
 * directly into JSSE objects — no keytool, no PKCS12 conversion step. Both Java
 * server variations share this so they can consume the same cert files as the
 * Go and Envoy examples.
 */
public final class PemUtils {
    private PemUtils() {}

    /** Load one or more X.509 certificates from a PEM file. */
    public static X509Certificate[] loadCertificates(Path pemFile) throws Exception {
        byte[] bytes = Files.readAllBytes(pemFile);
        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        List<X509Certificate> out = new ArrayList<>();
        for (Certificate c : cf.generateCertificates(new java.io.ByteArrayInputStream(bytes))) {
            out.add((X509Certificate) c);
        }
        return out.toArray(new X509Certificate[0]);
    }

    /** Load an EC private key from a PKCS#8 ("PRIVATE KEY") PEM file. */
    public static PrivateKey loadPrivateKey(Path pemFile) throws Exception {
        String pem = Files.readString(pemFile);
        String base64 = pem
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("\\s", "");
        byte[] der = Base64.getDecoder().decode(base64);
        // certgen writes EC (P-256) keys.
        return KeyFactory.getInstance("EC")
                .generatePrivate(new java.security.spec.PKCS8EncodedKeySpec(der));
    }

    /**
     * Build the server's KeyManagers from a cert PEM + key PEM. This is the
     * server's own identity; it is orthogonal to the authorization decision,
     * which lives in each variation's TrustManager.
     */
    public static KeyManager[] serverKeyManagers(Path certFile, Path keyFile) throws Exception {
        X509Certificate[] chain = loadCertificates(certFile);
        PrivateKey key = loadPrivateKey(keyFile);

        char[] pw = "changeit".toCharArray();
        KeyStore ks = KeyStore.getInstance("PKCS12");
        ks.load(null, null);
        ks.setKeyEntry("server", key, pw, chain);

        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(ks, pw);
        return kmf.getKeyManagers();
    }

    /** Build an in-memory KeyStore trusting the given CA certificate(s). */
    public static KeyStore trustStoreFromCa(Path caFile) throws Exception {
        X509Certificate[] cas = loadCertificates(caFile);
        KeyStore ts = KeyStore.getInstance("PKCS12");
        ts.load(null, null);
        for (int i = 0; i < cas.length; i++) {
            ts.setCertificateEntry("ca-" + i, cas[i]);
        }
        return ts;
    }

    /** Extract the first URI SAN (the SPIFFE ID) from a certificate, or null. */
    public static String uriSan(X509Certificate cert) throws IOException {
        try {
            var sans = cert.getSubjectAlternativeNames();
            if (sans == null) return null;
            for (List<?> entry : sans) {
                // GeneralName type 6 == URI (where SPIFFE IDs live).
                if (((Integer) entry.get(0)) == 6) {
                    return (String) entry.get(1);
                }
            }
        } catch (Exception e) {
            throw new IOException("failed reading SANs", e);
        }
        return null;
    }
}
