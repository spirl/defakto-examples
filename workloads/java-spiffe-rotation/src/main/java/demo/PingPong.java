package demo;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsExchange;
import com.sun.net.httpserver.HttpsParameters;
import com.sun.net.httpserver.HttpsServer;
import io.spiffe.provider.SpiffeSslContextFactory;
import io.spiffe.provider.SpiffeSslContextFactory.SslContextOptions;
import io.spiffe.workloadapi.DefaultX509Source;
import io.spiffe.workloadapi.X509Source;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

/**
 * mTLS ping-pong service built on java-spiffe. Every instance is both a server (GET /ping, GET /debug)
 * and a client that pings PEER_URL every INTERVAL_SECONDS.
 *
 * The X509Source is created once and never rebuilt, exactly like a long-running service would.
 * If a trust bundle rotation is not picked up by the SDK, pings start failing and only a restart fixes it.
 */
public class PingPong {

    static X509Source source;

    public static void main(String[] args) throws Exception {
        // SVIDs carry no DNS SANs; peer identity is checked by the SPIFFE trust manager instead.
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
        System.setProperty("java.util.logging.SimpleFormatter.format", "%1$tFT%1$tT.%1$tLZ %4$s %3$s: %5$s%6$s%n");

        int port = Integer.parseInt(env("PORT", "8443"));
        String peerUrl = env("PEER_URL", "");
        int interval = Integer.parseInt(env("INTERVAL_SECONDS", "5"));

        // Reads SPIFFE_ENDPOINT_SOCKET and keeps a Workload API stream open for SVID + bundle updates.
        source = DefaultX509Source.newSource();
        SSLContext ssl = SpiffeSslContextFactory.getSslContext(
                SslContextOptions.builder().x509Source(source).acceptAnySpiffeId().build());
        // Expire TLS sessions immediately so every ping does a full handshake (and a fresh bundle check)
        // instead of resuming a session that was verified against an old bundle.
        ssl.getClientSessionContext().setSessionTimeout(1);
        ssl.getServerSessionContext().setSessionTimeout(1);

        log("started as " + source.getX509Svid().getSpiffeId() + " " + state());

        HttpsServer server = HttpsServer.create(new InetSocketAddress(port), 0);
        server.setHttpsConfigurator(new HttpsConfigurator(ssl) {
            @Override
            public void configure(HttpsParameters params) {
                SSLParameters p = getSSLContext().getDefaultSSLParameters();
                p.setNeedClientAuth(true);
                params.setSSLParameters(p);
            }
        });
        server.createContext("/ping", ex -> reply(ex, "pong from " + source.getX509Svid().getSpiffeId()
                + " to " + peerId(ex) + "\n"));
        server.createContext("/debug", ex -> reply(ex, state() + "\n"));
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        log("listening on :" + port);

        // DefaultX509Source has no update callback, so poll what it holds and log changes.
        String[] last = {svidState(), bundleState()};
        Executors.newSingleThreadScheduledExecutor().scheduleWithFixedDelay(() -> {
            String svid = svidState(), bundle = bundleState();
            if (!svid.equals(last[0])) log("SVID UPDATED " + last[0] + " -> " + svid);
            if (!bundle.equals(last[1])) log("BUNDLE UPDATED " + last[1] + " -> " + bundle);
            last[0] = svid;
            last[1] = bundle;
        }, 1, 1, TimeUnit.SECONDS);

        if (peerUrl.isEmpty()) return;
        Executors.newSingleThreadScheduledExecutor().scheduleWithFixedDelay(() -> {
            // New client per ping: no pooled keep-alive connection hides a stale bundle.
            try (HttpClient client = HttpClient.newBuilder().sslContext(ssl).connectTimeout(Duration.ofSeconds(5)).build()) {
                HttpResponse<String> r = client.send(
                        HttpRequest.newBuilder(URI.create(peerUrl + "/ping")).timeout(Duration.ofSeconds(5)).build(),
                        HttpResponse.BodyHandlers.ofString());
                log("PING OK " + r.statusCode() + " " + r.body().trim() + " | " + state());
            } catch (Exception e) {
                log("PING FAIL " + rootCause(e) + " | " + state());
            }
        }, 0, interval, TimeUnit.SECONDS);
    }

    /** One-line snapshot of what the SDK currently holds: our SVID and the trust bundle used to verify peers. */
    static String state() {
        return svidState() + " " + bundleState();
    }

    static String svidState() {
        try {
            var svid = source.getX509Svid();
            var leaf = svid.getLeaf();
            return "svid[serial=" + leaf.getSerialNumber().toString(16)
                    + " exp=" + leaf.getNotAfter().toInstant()
                    + " issuer=" + fp(svid.getChain().size() > 1 ? svid.getChain().get(1) : leaf) + "]";
        } catch (Exception e) {
            return "svid[error: " + e + "]";
        }
    }

    static String bundleState() {
        try {
            var bundle = source.getBundleForTrustDomain(source.getX509Svid().getSpiffeId().getTrustDomain());
            return "bundle[" + bundle.getX509Authorities().stream()
                    .map(c -> fp(c) + " exp=" + c.getNotAfter().toInstant())
                    .sorted().collect(Collectors.joining(", ")) + "]";
        } catch (Exception e) {
            return "bundle[error: " + e + "]";
        }
    }

    static String peerId(HttpExchange ex) {
        try {
            var cert = (X509Certificate) ((HttpsExchange) ex).getSSLSession().getPeerCertificates()[0];
            return cert.getSubjectAlternativeNames().stream()
                    .map(san -> san.get(1).toString()).filter(s -> s.startsWith("spiffe://"))
                    .findFirst().orElse("unknown");
        } catch (Exception e) {
            return "unknown";
        }
    }

    /** First 16 hex chars of the SHA-256 of the cert: enough to compare against `openssl x509 -fingerprint -sha256`. */
    static String fp(X509Certificate c) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(c.getEncoded())).substring(0, 16);
        } catch (Exception e) {
            return "?";
        }
    }

    static void reply(HttpExchange ex, String body) throws java.io.IOException {
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        ex.sendResponseHeaders(200, b.length);
        try (var os = ex.getResponseBody()) {
            os.write(b);
        }
    }

    static String rootCause(Throwable t) {
        while (t.getCause() != null) t = t.getCause();
        return t.getClass().getSimpleName() + ": " + t.getMessage();
    }

    static String env(String k, String def) {
        String v = System.getenv(k);
        return v == null || v.isBlank() ? def : v;
    }

    static void log(String msg) {
        System.out.println(Instant.now() + " " + msg);
    }
}
