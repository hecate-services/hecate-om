# Anatomy of a hecate-service

A Hecate service is one OTP release, one OCI container, one
system-wide systemd-managed Podman unit running on a **realm
infrastructure node** (BEAM cluster, relay box, cooperative-
contributed service node — never a user laptop). Every service in
`hecate-services/hecate-*` follows the same layout.

## Repository layout

```
hecate-services/hecate-X/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── manifest.json                ← service descriptor (capabilities, ports)
├── Containerfile                ← multi-stage Erlang build
├── quadlet/
│   └── hecate-X.container       ← systemd Quadlet unit
├── rebar.config                 ← OTP deps incl. {hecate_om, "~> 0.1"}
├── src/
│   ├── hecate_X.app.src         ← `applications: [hecate_om, …]`
│   ├── hecate_X_app.erl         ← `start/2 -> hecate_om:boot(hecate_X_service)`
│   ├── hecate_X_sup.erl
│   └── hecate_X_service.erl     ← implements hecate_om_service behaviour
├── apps/                        ← vertical-sliced sub-apps (CMD/PRJ/QRY)
│   ├── do_thing/                CMD
│   ├── project_things/          PRJ
│   └── query_things/            QRY
└── .github/workflows/
    └── build-push.yml           ← ghcr.io publish on main + tags
```

## Lifecycle

```
podman pulls ghcr.io/hecate-services/hecate-X:latest
   ↓
systemd starts the container (Quadlet unit)
   ↓
Erlang VM boots → application:start(hecate_X)
   ↓
hecate_X_app:start/2 → hecate_om:boot(hecate_X_service)
   ↓
hecate_om:
   ├── loads the service-principal cert from
   │   /etc/hecate/secrets/service-cert.pem (mounted by the Quadlet)
   ├── registers capabilities() into hecate_om_capabilities
   ├── registers the service module into hecate_om_health
   ├── (v2) auto-rotates short-lived UCANs against hecate-realm
   └── calls hecate_X_service:start(Opts) → hecate_X_sup:start_link()
   ↓
hecate_om_capabilities:publish/0 fans capabilities onto macula bloom-channel
   ↓
GET /health (port 8470) ready to answer
   ↓
Service is live.
```

## What the service module must implement

Six callbacks. See `hecate_om_service` for the full type spec.

```erlang
-module(hecate_X_service).
-behaviour(hecate_om_service).
-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
```

That's the whole user-side surface. Health endpoint, mesh
advertisement, identity loading, container packaging — all handled
by `hecate_om` + the templates.

## Vertical slicing inside

A service may host its own CMD / PRJ / QRY tier internally. Same
vertical-slicing rules as user-domain apps. Example for `hecate-rag`:

```
apps/
├── embed_corpus/        CMD
│   ├── ingest_document/
│   ├── embed_document/
│   └── prune_chunks/
├── serve_retrieval/     CMD
├── project_chunks/      PRJ
└── query_chunks/        QRY
```

`hecate-om` enforces nothing here — it's a contract for the daemon
boundary, not for the daemon's internals.
