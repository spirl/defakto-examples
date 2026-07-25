# Rejecting mTLS connections by SPIFFE ID pattern

## What this demonstrates

This demo shows how a server can **reject an mTLS connection based on a pattern
_within_ the caller's SPIFFE ID** — not based on the trust domain.

Rejecting by trust domain is already handled implicitly by SPIFFE: if two
workloads are in different trust domains and you don't federate, their trust
bundles simply don't contain each other's keys, so validation fails. The
interesting and more common case is: **all callers are in the same trust
domain, and you want to admit only some of them** based on where they sit
within it (namespace, service account, region, …). That's what this repo
demonstrates.

It contains the **same authorization rule implemented five ways** across three
server ecosystems. Go and Java are each shown two ways — an off-the-shelf
config/library style and a hand-rolled custom-code style. Envoy is shown one
way, config only:

| Ecosystem | Config / library style | Custom-code style |
|---|---|---|
| **Go**    | `go-spiffe` authorizer      | hand-rolled `VerifyPeerCertificate` |
| **Java**  | `java-spiffe` trust manager | hand-rolled `X509ExtendedTrustManager` |
| **Envoy** | static `match_typed_subject_alt_names` config | — *(not possible; see below)* |

> **Why no custom-code Envoy example?** Envoy has no hook to run custom decision
> logic *inside* the TLS handshake. Its custom-logic mechanisms (Lua, WASM,
> `ext_authz`) and its RBAC filters all run *after* the handshake completes, at
> L4/L7 — so a handshake-time rejection in Envoy is necessarily the static SAN
> matcher. Doing the check at L7 instead is a legitimate approach with different
> trade-offs; see [Important considerations for production use](#important-considerations-for-production-use).

A single small Go client calls each server, presenting either an **allowed** or
a **denied** identity, so you can see both outcomes. The demo also focuses on
**how you operate and debug this** — in particular, that a rejected client
usually gets an opaque error while the real reason lives in the server logs.

Everything runs locally on one machine with self-signed certs; there is no
SPIFFE infrastructure to stand up, no Docker, and no extra backend server to run.

## The scenario

Every identity lives in the **same** trust domain, `example.org`, following a
common SPIFFE path layout `spiffe://<trust-domain>/ns/<namespace>/sa/<service>`:

| Role | SPIFFE ID | Result |
|---|---|---|
| Server | `spiffe://example.org/ns/prod/sa/server` | — |
| Client **allowed** | `spiffe://example.org/ns/prod/sa/frontend` | ✅ accepted |
| Client **denied** | `spiffe://example.org/ns/dev/sa/frontend` | ❌ rejected |

**The rule:** _admit a caller only if its SPIFFE ID path begins with
`/ns/prod/`._ The `dev` client is a perfectly valid, CA-signed identity in the
**same** trust domain — it is rejected purely because of its **path**.

The single source of truth for the identities and the rule is
[`common/spiffeid/spiffeid.go`](common/spiffeid/spiffeid.go) (Go) and
[`Rule.java`](java-server/src/main/java/com/example/Rule.java) (Java). See
[Changing the pattern](#changing-the-pattern) to enforce a suffix or any other
shape of rule.

---

# Install and run

## 1. Clone the repository

The demo lives in the `authz/tls-handshake-reject` subdirectory of the
`defakto-examples` repo. Clone it and change into that directory:

```bash
git clone https://github.com/spirl/defakto-examples.git
cd defakto-examples/authz/tls-handshake-reject
```

All commands below are run from this directory.

## 2. Set up dependencies

Prerequisites are minimal and are only needed for the examples you actually run:

- **Go 1.22+** — always required (generates the certs, builds the client). <https://go.dev/dl/>
- **A JDK 17+** — only for the Java examples. <https://adoptium.net>. Maven is
  **not** needed separately — the repo ships the Maven wrapper (`./mvnw`).
- **`func-e`** — only for the Envoy examples. A single self-contained binary
  that downloads the correct Envoy build on first run (no Docker, no daemon, no
  root).

Run the bootstrap script. It installs the one demo-specific dependency
(`func-e`) into `./bin`, and reports whether Go and a JDK are present (it does
**not** silently install language runtimes):

```bash
scripts/bootstrap.sh
```

> You can skip this step entirely — `scripts/demo.sh` (next) checks
> dependencies itself, tells you if anything is missing, and offers to install
> `func-e` for you. `scripts/preflight.sh` is also available to just check your
> toolchains without installing anything.

## 3. Run an example

`scripts/demo.sh <example>` does everything for one example: verifies its
dependencies, generates certs if needed, builds the server and client, starts
the server, calls it once as the **allowed** client and once as the **denied**
client, prints the server-side log, then stops the server.

```bash
scripts/demo.sh go-spiffe
```

Abridged output — note the allowed client succeeds, the denied client fails,
and the **server log names the exact rejected SPIFFE ID and why**:

```
→ client as 'allowed':
    ✓ Request SUCCEEDED: HTTP 200 OK
      Server said: hello, authorized client spiffe://example.org/ns/prod/sa/frontend
→ client as 'denied':
    ✗ Request FAILED (no HTTP response received).
      Go error: ... remote error: tls: bad certificate
Server-side log — note it names the exact rejected SPIFFE ID:
    ALLOW handshake: client SPIFFE ID "spiffe://example.org/ns/prod/sa/frontend" ...
    DENY handshake: client SPIFFE ID "spiffe://example.org/ns/dev/sa/frontend" path "/ns/dev/sa/frontend" does NOT start with "/ns/prod/"
```

The example names are: `go-spiffe`, `go-custom`, `java-spiffe`, `java-custom`,
`envoy-static` (described in detail [below](#the-examples-in-detail)).

If a dependency is missing, `demo.sh` stops **before running anything** and
tells you exactly what to do — no confusing mid-run crash:

```
Hold on — some dependencies aren't set up yet:
  ✗ java   — needed for the Java examples. Install a JDK 17+: https://adoptium.net
Still missing: java
Install the item(s) above (or run scripts/bootstrap.sh), then re-run:
    scripts/demo.sh go-spiffe
```

## 4. Run everything

```bash
scripts/demo.sh all      # runs all five examples in sequence
```

## Running a server manually

If you'd rather drive the pieces yourself instead of using `demo.sh`, first
generate the identity material once (writes PEM files into `certs/`):

```bash
go run ./common/certgen
```

Then start any one server, and call it with the client. The exact per-example
commands are listed in [The examples in detail](#the-examples-in-detail). The
client is always:

```bash
go run ./common/client -addr localhost:<port> -id allowed   # -> success
go run ./common/client -addr localhost:<port> -id denied    # -> rejected
```

---

# The examples in detail

All five enforce the identical rule ("path must start with `/ns/prod/`") and all
reject during the **TLS handshake**; they differ only in **how** the check is
wired in. Each section links to the exact source file so you can read the
implementation.

| # | Example | Port | Rejects at | Source |
|---|---|---|---|---|
| 1 | `go-spiffe`    | 8443 | TLS handshake | [go-server/config-based/main.go](go-server/config-based/main.go) |
| 2 | `go-custom`    | 8444 | TLS handshake | [go-server/custom/main.go](go-server/custom/main.go) |
| 3 | `java-spiffe`  | 8445 | TLS handshake | [SpiffeLibServer.java](java-server/src/main/java/com/example/SpiffeLibServer.java) |
| 4 | `java-custom`  | 8446 | TLS handshake | [CustomTrustManagerServer.java](java-server/src/main/java/com/example/CustomTrustManagerServer.java) |
| 5 | `envoy-static` | 8447 | TLS handshake | [envoy/static-san/envoy.yaml](envoy/static-san/envoy.yaml) |

## 1. Go — library (`go-spiffe`)

Uses the official [`go-spiffe`](https://github.com/spiffe/go-spiffe) library.
`tlsconfig.MTLSServerConfig` builds the mTLS `*tls.Config`, and
`tlsconfig.AdaptMatcher` supplies our decision as a matcher over the parsed
`spiffeid.ID` (checking the path prefix). The library validates the chain and
parses the URI SAN for you.

- **Code:** [`go-server/config-based/main.go`](go-server/config-based/main.go)
- **Run:** `scripts/demo.sh go-spiffe`  — or manually: `go run ./go-server/config-based` then call port **8443**
- **Rejects at:** the TLS handshake (returning an error from the matcher aborts it).

## 2. Go — custom code

The standard-library approach: no SPIFFE library at all. A hand-written
`tls.Config.VerifyPeerCertificate` callback runs after Go verifies the client
chain, pulls the URI SAN off the leaf, and matches it against a regex.

- **Code:** [`go-server/custom/main.go`](go-server/custom/main.go)
- **Run:** `scripts/demo.sh go-custom`  — or manually: `go run ./go-server/custom` then call port **8444**
- **Rejects at:** the TLS handshake (returning a non-nil error aborts it).

## 3. Java — library (`java-spiffe`)

Uses the [`java-spiffe`](https://github.com/spiffe/java-spiffe) provider.
An `X509Bundle` loads the trust bundle and a `SpiffeTrustManager` validates the
peer and hands the parsed `SpiffeId` to a `SpiffeIdVerifier` lambda that applies
the path-prefix rule. Served by the JDK's built-in `HttpsServer`.

- **Code:** [`SpiffeLibServer.java`](java-server/src/main/java/com/example/SpiffeLibServer.java)
  (shared helpers: [`HttpServerRunner.java`](java-server/src/main/java/com/example/HttpServerRunner.java),
  [`PemUtils.java`](java-server/src/main/java/com/example/PemUtils.java))
- **Run:** `scripts/demo.sh java-spiffe`  — or manually:
  ```bash
  cd java-server && ./mvnw -q package && cd ..
  java -cp java-server/target/java-server.jar com.example.SpiffeLibServer   # port 8445
  ```
- **Rejects at:** the TLS handshake (the verifier throws, aborting it).

## 4. Java — custom code

Hand-rolls an `X509ExtendedTrustManager` that **wraps** the platform trust
manager (built from our CA, so normal chain validation still happens) and adds
a URI-SAN regex check on top. No SPIFFE library. Also served by `HttpsServer`.

- **Code:** [`CustomTrustManagerServer.java`](java-server/src/main/java/com/example/CustomTrustManagerServer.java)
- **Run:** `scripts/demo.sh java-custom`  — or manually (after the `./mvnw package` above):
  ```bash
  java -cp java-server/target/java-server.jar com.example.CustomTrustManagerServer   # port 8446
  ```
- **Rejects at:** the TLS handshake (throwing `CertificateException` aborts it).

## 5. Envoy — static config (no code)

Pure configuration. `match_typed_subject_alt_names` inside the
`DownstreamTlsContext` requires the client's URI SAN to match a regex; Envoy
aborts the handshake if it doesn't. An accepted request gets a `direct_response`
(no backend server needed).

- **Code:** [`envoy/static-san/envoy.yaml`](envoy/static-san/envoy.yaml)
- **Run:** `scripts/demo.sh envoy-static`  — or manually (from repo root):
  `./bin/func-e run -c envoy/static-san/envoy.yaml` then call port **8447**
- **Rejects at:** the TLS handshake.
- **Note:** there is no custom-code Envoy variation because Envoy cannot run
  custom decision logic during the handshake — its Lua/WASM/`ext_authz`/RBAC
  hooks all run *after* it, at L4/L7. See
  [Important considerations](#important-considerations-for-production-use).

## Shared building blocks

- **Client:** [`common/client/main.go`](common/client/main.go) — the one mTLS
  client used against all five servers (`-id allowed` / `-id denied`).
- **Cert generator:** [`common/certgen/main.go`](common/certgen/main.go) —
  mints the CA + the three SPIFFE leaf certs into `certs/`.
- **Rule & identities:** [`common/spiffeid/spiffeid.go`](common/spiffeid/spiffeid.go)
  and [`Rule.java`](java-server/src/main/java/com/example/Rule.java).

---

# Finding logs and output

- **`scripts/demo.sh` runs:** each server's full output is saved to
  **`logs/<example>.log`** (e.g. `logs/go-spiffe.log`, `logs/envoy-static.log`).
  The script also prints the relevant lines to your terminal.
- **Running a server manually:** the server writes its log to **stdout** in the
  terminal where you started it. The client prints its result (success, or the
  transport/HTTP error) to its own stdout.
- **Certs:** generated identity material is in **`certs/`**.

## Understanding & debugging rejections

A central point of this demo: **what the client sees is almost never the real
reason.** How you debug depends on _where_ the rejection happens.

**What the client experiences:** every example rejects during the handshake, so
a denied client gets an **opaque transport error** — e.g. `remote error: tls:
bad certificate`, `tls: unknown certificate`, or `connection reset by peer` —
with no HTTP status and no reason.

This is deliberate: TLS has no way to carry an "authorization denied, because X"
message during the handshake. If you need callers to get a _readable_ reason,
you must reject at the application layer (L7) instead — see
[Important considerations](#important-considerations-for-production-use). The
demo client prints a hint box pointing you to the server logs.

**Where the real reason lives (server side):**

- **Go / Java** — the verify hook logs an explicit line naming the rejected
  SPIFFE ID and the rule it failed, e.g.:
  ```
  DENY handshake: client SPIFFE ID "spiffe://example.org/ns/dev/sa/frontend" ... does NOT start with "/ns/prod/"
  ```

- **Envoy (static SAN matcher)** — the trickiest to debug: at the **default**
  log level Envoy does **not** print the SAN mismatch. Two ways to see it:
  - Raise the log level: `./bin/func-e run -c envoy/static-san/envoy.yaml -l debug`, then look for:
    ```
    verify cert failed: SAN matcher, certificate SANs are [spiffe://example.org/ns/dev/sa/frontend]
    ...TLS_error:...CERTIFICATE_VERIFY_FAILED...
    ```
  - Check the admin stats counter (no restart needed):
    ```bash
    curl -s http://127.0.0.1:9901/stats | grep ssl.fail_verify_san
    # listener.127.0.0.1_8447.ssl.fail_verify_san: 1
    ```
    Other useful counters: `ssl.fail_verify_error`, `ssl.fail_verify_no_cert`, `ssl.handshake`.

The Envoy example also exposes an admin interface on `:9901` — e.g.
`curl -s http://127.0.0.1:9901/certs` to inspect loaded certs.

---

# Changing the pattern

The demo enforces a namespace **prefix**, but the same mechanism enforces any
shape of rule. You only change the pattern, never the enforcement code. See the
worked examples in the comments of
[`common/spiffeid/spiffeid.go`](common/spiffeid/spiffeid.go) and
[`Rule.java`](java-server/src/main/java/com/example/Rule.java), e.g.:

```
prefix (this demo):    ^spiffe://example\.org/ns/prod/.*$
suffix (a service):    ^spiffe://example\.org/ns/[^/]+/sa/frontend$
a set of namespaces:   ^spiffe://example\.org/ns/(prod|staging)/.*$
```

- Go custom / Java custom / Envoy static: edit the regex.
- Go / Java library: edit the structured path-prefix check (or swap the matcher/verifier logic).

# Important considerations for production use

> **Read this before adopting the approach.** Enforcing SPIFFE-ID authorization
> during the mTLS handshake is a legitimate and useful pattern — which is why
> this demo implements it across three ecosystems. But it comes with two
> constraints that are easy to miss and important to plan around:
> **(1) a rejected client does not get an intuitive error message, and
> (2) exactly what it *does* get is dictated by your server and client
> frameworks, not by you.** The sections below lay out these trade-offs so you
> can decide where in your stack the check belongs.

## Strengths of rejecting at the TLS handshake

- **Fails fast, low surface.** The connection is refused before any request is
  parsed or application code runs — less wasted work, and a smaller attack
  surface for unauthorized peers.
- **Defense in depth.** Identity is enforced right at the transport boundary,
  independent of (and in addition to) anything the application does.
- **Little or no code.** Pure config (Envoy's static matcher) or a handful of
  lines with a library.
- **Uniform.** It applies to the whole connection, not per handler or route.

## The main trade-off: handshake rejections are opaque

- **TLS has no mechanism to carry arbitrary text back to the peer during the
  handshake.** When the server aborts, all that goes back is a single fixed TLS
  alert code — there is no reason string.
- **Which alert code is sent depends on your server framework.** In this demo:
  Go sends `bad_certificate`, Envoy's static matcher sends `certificate_unknown`,
  and JSSE sends a `certificate_unknown`-class alert. None emit `access_denied(49)`
  — the spec's "valid certificate, but access control denied it" code — and none
  expose a knob to choose it.
- **What the caller sees depends on the client's TLS library.** Some surface the
  alert as a readable message (a Go client prints `remote error: tls: …`); many
  collapse any handshake failure into a generic "handshake failed."
- **Net:** the caller generally cannot learn *why* it was rejected; the real
  reason has to come from your server logs/metrics (as every example here does).
  For internal service-to-service traffic that is usually fine. For API
  consumers — or anyone who needs to self-diagnose — it can be real friction.

A couple of other considerations when choosing among the five variations:

- **Static config only matches patterns known at config time.** Envoy's static
  matcher can't compute "the server's *own* prefix" at runtime; custom code or a
  library authorizer can make dynamic decisions.
- **Library vs. hand-rolled.** `go-spiffe` / `java-spiffe` integrate with the
  SPIFFE Workload API and cert rotation and parse SPIFFE IDs safely; hand-rolled
  code has no dependencies but you must be careful to preserve full chain
  validation yourself.

## Why some teams put all authorization at L7

Because of the opacity above, some audiences prefer to keep **all**
authorization at the application layer. The common pattern splits the two
concerns:

1. **Authenticate with mTLS using a broad / permissive TLS policy** — accept any
   certificate signed by your CA and establish the caller's identity. An opaque
   handshake failure here is acceptable: it only ever means "couldn't prove
   identity."
2. **Authorize one layer up** — do the SPIFFE/SAN prefix matching at L7 (Envoy
   RBAC / `ext_authz`, or your own middleware that runs after the Go/Java
   handshake completes), where you fully control the status code, response body,
   and error detail — a real, debuggable `403` with a reason. You can also
   combine identity with request attributes (path, method, headers) there.

Every example in this demo rejects at the handshake, so it does not itself show
this split — but the idea is straightforward: TLS validates only the
chain/identity, and the SPIFFE decision plus a readable `403` live in an L7
filter (e.g. Envoy RBAC / `ext_authz`) or in your own HTTP handler that runs
after the Go/Java handshake completes.

This is why service meshes (Istio, Linkerd, Consul) commonly separate
**"authenticate via mTLS"** (opaque failure is fine — it's just proving
identity) from **"authorize the request"** (rich, debuggable responses) into two
distinct layers.

None of this makes handshake-level rejection wrong — the two approaches aren't
mutually exclusive, and some teams do both (a transport-level identity gate
*plus* an L7 policy). The right choice comes down to whether your callers need
actionable error detail and how dynamic your authorization policy has to be.

# Repository layout

```
common/spiffeid/          shared identities + the authorization rule (Go)
common/certgen/           generates the CA + SPIFFE leaf certs into certs/
common/client/            the mTLS client used against every server
go-server/config-based/   Go, go-spiffe library
go-server/custom/         Go, hand-rolled VerifyPeerCertificate
java-server/              Maven project; two main classes (lib + custom)
envoy/static-san/         Envoy pure-config SAN matcher
scripts/bootstrap.sh      install func-e (safe, project-local); report Go/JDK
scripts/preflight.sh      toolchain check (installs nothing)
scripts/demo.sh           run one/all examples end-to-end (gates on deps first)
certs/                    generated identity material (gitignored)
logs/                     server logs written by demo.sh (gitignored)
```

# Notes

- **Self-signed, not from a running SPIFFE issuer.** `certgen` mints the CA and
  SVIDs directly so the demo has zero runtime dependencies. What matters for the
  check — a CA-signed leaf whose URI SAN is a SPIFFE ID — is identical to what a
  SPIFFE issuer produces. In production, the trust bundle and the server's own
  SVID would come from the SPIFFE Workload API and rotate automatically; the
  authorization logic shown here is unchanged.
- **Ports:** 8443–8447 (one per example). Envoy admin: 9901.
- **Cleanup:** `rm -rf certs logs bin target java-server/target`. `func-e`'s
  downloaded Envoy lives in `~/.func-e` (or `$FUNC_E_HOME`).
