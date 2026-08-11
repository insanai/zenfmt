= The Server

zenfmt converts documents in-process through the engine, the CLI, the
Python library, and a browser WebAssembly build. The server (ZDS 0016)
adds the missing surface: a long-running process that accepts documents
over HTTP and answers with Markdown and structured reports, in the shape
teams already run Apache Tika for. It starts in one command, and it grows
into an administered service only when the deployment warrants it.

== Two postures

Open mode is one command with no state:

```sh
zenfmt serve
```

It binds `127.0.0.1:8998`, converts whatever arrives, and serves a small
converter interface. Every request acts as an anonymous user; nothing
touches disk. This is the drop-in Tika-class deployment.

Secure mode is a deliberate upgrade:

```sh
zenfmt serve --secure --data-dir /var/lib/zenfmt
```

It turns on accounts, sessions, API keys, an audit trail, and the
administration interface, all stored in an embedded database under the
data directory. On the first start it prints a one-time administrator
password to stderr, framed apart from the log stream; that password must
be changed at first login and is never shown again.

Binding a non-loopback address in open mode is permitted but loud: the
server emits the `server.open-network-bind` warning at startup, because
every network peer can then convert documents anonymously. For a service
reachable beyond loopback, run secure mode behind a TLS-terminating
reverse proxy.

== The conversion API

The request body is the document; metadata rides in the query string and
headers, so `curl` stays one line:

```sh
curl -s -T report.docx \
  "http://127.0.0.1:8998/api/v1/convert?to=markdown" \
  -H "Accept: text/markdown"
```

`?to=` selects the writer, `?from=` overrides detection, and `?strict=`
selects the strictness grade with the same spellings as the CLI
(`content`, `structure`, `exact`). `PUT` is accepted as an alias for
`POST` to ease Tika muscle memory.

With `Accept: text/markdown` the response is the artifact bytes, chunked,
with `X-Zenfmt-Report-Count` and `X-Zenfmt-Exit-Class` summary headers.
With `Accept: application/json` the response is the envelope: `status`,
`artifact`, `artifact_name`, `resources`, `manifest` (the canonical
manifest embedded verbatim), `reports`, `exit_class`, `source_format`,
and `output_format`. The field names and semantics mirror the Python
`Conversion` model, so a client that already reads one reads the other.

A failed conversion returns the failure envelope with `status: "failed"`,
the engine's own reports, and no artifact. The HTTP status follows the
exit class: usage is `400`, limit is `413`, conversion is `422`. The
server never rewrites a report; API callers and the interface render the
identical structured diagnostic.

== Discovery, health, and metrics

`GET /api/v1/formats` returns the capability document: the readers,
writers, extensions, and the limits this deployment actually enforces.
`GET /api/v1/status` returns the version, mode, uptime, and bounded
counters.

`GET /openapi.json` returns the embedded OpenAPI 3.1 contract. The web
interface presents its practical entry points at `/docs`, which remains
available without a session in both modes. Protected account and
administration pages still require sign in.

The operational plane is unauthenticated in both modes and exposes no
data beyond check names: `GET /healthz` is liveness, `GET /readyz` is
readiness (the worker pool and, in secure mode, a store ping), and
`GET /metrics` is Prometheus text exposition. Every metric carries the
`zenfmt_` prefix and only comptime-enum label values, so a scrape
allocates nothing and cardinality is bounded by construction. The first
release serves the operational plane on the main listener.

The monitoring runbook maps the shipped signals to metrics. These signals
cover error rate through `zenfmt_http_requests_total`, saturation through
`zenfmt_http_rejected_total` and `zenfmt_conversions_active`, and
authentication pressure through `zenfmt_auth_failures_total`.

== Accounts, sessions, and keys

Secure mode has exactly two roles, `administrator` and `user`, so the
authorization matrix stays small enough to test exhaustively. A browser
authenticates with a session cookie and a per-session CSRF token, which
the interface sends on every state-changing request; a program
authenticates with an API key presented as
`Authorization: Bearer zfk_<id>.<secret>`. Bearer requests are
CSRF-exempt by construction.

Passwords are stored as Argon2id PHC strings (the OWASP interactive
profile); tokens and key secrets are stored only as SHA-256 digests and
compared in constant time. A key's secret appears exactly once, in the
response that creates it. The last administrator cannot be deleted,
demoted, or disabled — the API refuses with `server.last-administrator`,
and the interface disables the impossible action for guidance while the
API stays authoritative.

Administrators manage accounts under `/api/v1/users` and read the audit
log under `/api/v1/audit`. The audit table records administrative fact —
account changes, logins, key lifecycle, server start and stop — under a
closed verb set, with bounded retention. Conversion requests are metered
in metrics and logs, not audited per request.

== The interface

The web interface is a Zig program. It follows the architecture Zig uses
to serve its own standard-library documentation: a static HTML shell, one
fixed JavaScript glue file, and a WebAssembly module compiled from Zig
that renders every page. The module owns all interface state and markup;
the glue holds no product logic, only the browser bridge. Styling is
vendored daisyUI 5 over Tailwind 4 — a committed stylesheet, generated
offline, with no CDN, no npm build at CI time, and no third-party
runtime code. Material style surfaces, elevation, visible state, and large
interaction targets provide the component language. Bold editorial
typography and generous spacing keep the page easy to scan. Routine
conversion has one clear path from document selection to the Convert
button. Detailed controls remain visually secondary, while account changes
and destructive administration ask for deliberate confirmation. A System /
Light / Dark theme selector follows the operating system by default and
remembers an explicit choice.

The interface is the first client of the public REST API: it calls
exactly the documented routes, with no private endpoints. It requires
JavaScript and WebAssembly; the `<noscript>` page shows the copy-pasteable
`curl` line, because the API, not the interface, is the no-script path.
The OpenAPI document, vendor styles, first party styles, JavaScript bridge,
HTML shell, and interface WebAssembly are embedded in the same executable.

== Deployment

The server is one binary, one optional directory, and one port. A
released `zenfmt` contains the engine, the HTTP service, the embedded
database and its migrations, and every interface asset; it needs no
adjacent bundle, Java runtime, Python environment, model directory, npm
tree, or repository checkout. The `-Dserver=false` build is the smaller
pure-converter binary for size-sensitive targets.

The standard library ships no TLS server, so in-process TLS is out of
scope. The supported deployments are loopback (the default), a private
network with `--secure`, or a TLS-terminating reverse proxy with
`--behind-proxy`. That option asserts that a trusted TLS terminating proxy
protects the server and marks cookies `Secure`. The server ignores
`Forwarded` and `X-Forwarded-For`, so attribution and rate limiting use the
immediate socket peer. The deployment guide ships nginx and Caddy fragments
and a manual verification checklist.

Upgrades are stop, replace the binary, start; migrations run forward
automatically, and a store whose schema is newer than the binary refuses
to start rather than risk corruption. Backups are an operator action
through the embedded database's own tooling against the data directory.

== Tika migration

The server is comparable to Tika Server as an operational extraction
service, but the first release is not a wire-compatible replacement. The
accepted `PUT` method helps existing scripts, but zenfmt does not expose
Tika paths such as `/tika`, `/rmeta`, `/meta`, or `/unpack`, and it does
not copy Tika's response metadata or error bodies. A migration changes
the request path to `/api/v1/convert` and chooses either zenfmt Markdown
or the JSON envelope explicitly.

#table(
  columns: (auto, 1fr),
  table.header([*Tika request*], [*zenfmt equivalent*]),
  [`PUT /tika` (text extraction)], [`PUT /api/v1/convert?to=markdown`
    with `Accept: text/markdown`.],
  [`PUT /rmeta/text` (metadata + text)], [`PUT /api/v1/convert` with
    `Accept: application/json`; the manifest carries the structured
    metadata.],
  [`/meta`, `/unpack`, `/detect`], [Not offered; detection is automatic
    and resources travel inside the JSON envelope.],
)
