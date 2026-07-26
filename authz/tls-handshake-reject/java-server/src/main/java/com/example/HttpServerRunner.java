package com.example;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.security.cert.X509Certificate;
import java.time.LocalTime;
import java.time.format.DateTimeFormatter;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSession;

import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsExchange;
import com.sun.net.httpserver.HttpsParameters;
import com.sun.net.httpserver.HttpsServer;

/**
 * Shared boilerplate: start a JDK built-in HttpsServer configured for mTLS
 * ("need client auth") using the supplied SSLContext. The authorization
 * decision lives in whichever TrustManager the caller put inside that
 * SSLContext, so this class is identical for both Java variations.
 *
 * Because the rejection happens during the TLS handshake (inside the trust
 * manager), a denied client never reaches the request handler below — it only
 * sees a transport-level failure. That is the key operational point the demo
 * highlights, and it is why the meaningful log lines are printed from the trust
 * managers, not from here.
 */
public final class HttpServerRunner {
    private HttpServerRunner() {}

    static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("HH:mm:ss.SSS");

    public static void log(String tag, String msg) {
        System.out.printf("[%s %s] %s%n", tag, LocalTime.now().format(TS), msg);
    }

    public static void start(int port, SSLContext sslContext, String tag) throws Exception {
        HttpsServer server = HttpsServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        server.setHttpsConfigurator(new HttpsConfigurator(sslContext) {
            @Override
            public void configure(HttpsParameters params) {
                SSLParameters p = getSSLContext().getDefaultSSLParameters();
                p.setNeedClientAuth(true); // require + verify client cert (mTLS)
                params.setSSLParameters(p);
                params.setNeedClientAuth(true);
            }
        });

        server.createContext("/", exchange -> {
            // Only authorized clients get here.
            String clientId = "<unknown>";
            try {
                SSLSession session = ((HttpsExchange) exchange).getSSLSession();
                X509Certificate leaf = (X509Certificate) session.getPeerCertificates()[0];
                clientId = PemUtils.uriSan(leaf);
            } catch (Exception ignored) {
            }
            log(tag, "serving request for authorized client " + clientId);
            byte[] body = ("hello, authorized client " + clientId + "\n").getBytes();
            exchange.sendResponseHeaders(200, body.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(body);
            }
        });

        server.setExecutor(null);
        log(tag, "listening on https://127.0.0.1:" + port);
        server.start();
    }
}
