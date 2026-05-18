# Container deployment

Every `hecate-services/hecate-X` ships as an OCI container image to
`ghcr.io/hecate-services/hecate-X` and runs on **realm infrastructure
nodes** under system-wide systemd-managed Podman (Quadlet units),
orchestrated by the existing `hecate-gitops` reconciler.

## What nodes does this run on

| Node | Role | Today | Future |
|------|------|-------|--------|
| beam00–03 (Tienen home cluster) | Realm services + dev workloads | ✅ canonical | continues |
| Linode relay box (rented in Paris) | Edge realm services + relay-net | ✅ runs macula-station | hosts services as scale dictates |
| Cooperative-contributed nodes (future) | Distributed realm services | ⏳ | new nodes join via realm provisioning |
| **User laptops / MaculaOS** | hecate-daemon (per-identity) + macula-station | ✅ | services do **not** run here |

The line is hard: hecate-services run **for the realm, on realm
infrastructure**. A user's laptop is a citizen, not an institution
— it consults services across the mesh, doesn't host them.

## The image

Built by `Containerfile` (see `templates/Containerfile.tmpl`):

- **Stage 1** — `erlang:27-alpine`: fetch deps, `rebar3 as prod tar`.
- **Stage 2** — `alpine:3.20`: just `libstdc++`, `ncurses-libs`,
  `openssl`, the release tarball, and the entry script.

Final image ~80 MB. Embedded ERTS. `HEALTHCHECK` hits
`/health` on port 8470 every 30 s.

## CI publish

`.github/workflows/build-push.yml` (template in
`templates/ci-build-push.yml.tmpl`):

- Triggers on push to `main` (publishes `:latest`) and on `vX.Y.Z`
  tags (publishes `:X.Y.Z`).
- Uses `${{ secrets.GITHUB_TOKEN }}` to push to ghcr.io under the
  `hecate-services` org.
- Codeberg has Forgejo Actions disabled per the migration pattern;
  CI runs on the GitHub mirror.

## Filesystem on an infrastructure node

System-wide paths (not user home):

```
/etc/hecate/
├── secrets/                       ← realm-signed service-principal certs
│   ├── hecate-rag/
│   │   └── service-cert.pem
│   ├── hecate-dns/
│   │   └── service-cert.pem
│   └── …
├── gitops/
│   ├── system/
│   │   ├── hecate-rag.container   ← Quadlet (declarative)
│   │   ├── hecate-rag.env         ← per-service env
│   │   ├── hecate-dns.container
│   │   └── hecate-llm.container
│   └── reconciler.log
└── trust/                          ← realm root keys for verification
    └── realm-root.pub

/bulk0/hecate/                      ← per-service state on the beam node's bulk drive
├── hecate-rag/
│   ├── data/                       (SQLite read models)
│   └── index/                      (persisted vector index files)
├── hecate-dns/
│   └── zones/
└── hecate-llm/
    └── models/                     (downloaded ONNX / GGUF blobs)

/run/macula/
└── station.sock                    (macula-station's local socket)
```

Beam-cluster note: application-specific data MUST live on the
`/bulk` drives per the existing convention (see workspace
`CLAUDE.md`). The boot eMMC is for OS only.

## How a service lands on a node

1. **CI** builds + pushes image: `ghcr.io/hecate-services/hecate-X:0.3.2` and `:latest`.
2. **Operator** commits the Quadlet + env file to `hecate-gitops`:
   ```
   gitops/by-node/beam00/hecate-rag.container
   gitops/by-node/beam00/hecate-rag.env
   ```
3. **hecate-gitops reconciler** on beam00 watches its node-bound dir,
   symlinks the `.container` into `/etc/containers/systemd/`.
4. **systemd** (system-wide) generates a unit from the Quadlet,
   starts it.
5. **Podman** pulls `:latest`, attaches the volumes, starts the
   container. `AutoUpdate=registry` re-pulls on the next sweep when
   `:latest` advances.
6. **Service** boots, mounts its realm-signed cert, attaches to
   `macula-station` via the station socket, advertises capabilities
   onto the mesh, answers `/health`.

## Provisioning the service-principal cert (v1)

Before step 2 above, the realm has to mint the credential. v1 is a
small admin script run from a realm-steward's box:

```bash
hecate-realm-admin services provision \
    --service hecate-rag \
    --node    beam00 \
    --scope   "publish_summary,answer_query" \
    --ttl     365d \
    --out     ./out/hecate-rag-beam00-cert.pem
```

The cert is then copied (or committed in encrypted form) into
`gitops/secrets/by-node/beam00/hecate-rag/service-cert.pem` and the
reconciler places it under `/etc/hecate/secrets/hecate-rag/`.

v2 wires this into a realm HTTP endpoint and a gitops-trigger so the
human step disappears. See `identity_model.md`.

## Quadlet template

See `templates/quadlet.container.tmpl`. Highlights:

- `Image=ghcr.io/hecate-services/{{service_name}}:latest`
- `AutoUpdate=registry`
- `After=macula-station.service` + `Requires=macula-station.service`
- Mounts `/etc/hecate/secrets/<service>:/etc/hecate/secrets:ro`
- Mounts `/bulk0/hecate/<service>:/var/lib/<service>:rw`
- Mounts `/run/macula:/run/macula` (station socket)
- `PublishPort=127.0.0.1:8470:8470` (health endpoint, loopback only)
- `User=hecate` / `Group=hecate` (dedicated service user, never root)
- `WantedBy=multi-user.target` (system instance, not `--user`)

## Network

Services do not open externally-routable ports. They reach the
local macula-station over its Unix socket; all cross-service and
cross-node traffic flows through the station.

Health endpoint is exposed on `127.0.0.1:8470` only — for podman's
HEALTHCHECK and local debugging on the host. Not reachable from
outside the box.

## Rollback

`AutoUpdate=registry` always pulls `:latest`. Pin to a specific
semver by editing the Quadlet's `Image=` to `:0.3.2` and committing
to `hecate-gitops`. Reconciler picks it up on the next sweep.

## Multi-arch

CI today builds `linux/amd64` only. Beam cluster is x86_64. Add
`linux/arm64` to the matrix when the first arm64 service node
joins.
