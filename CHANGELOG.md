# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.8.0] - 2026-07-26

### Changed

- **Requires macula `~> 7.0`** (was `~> 6.0`). macula 7.0.0 teaches the
  canonical encoder floats (IEEE 754 binary64, RFC 8949 major type 7), so
  services publish raw float telemetry again and stop scaling to integers to
  get a number past our own codec.

  This is a WIRE change upstream: a peer on macula 6.x finds no clause for
  major 7 and rejects a frame carrying a float. Both ends of any topic that
  will carry floats must be on 7.x, so roll stations and services together
  rather than piecemeal.

  0.7.0 was the stopgap that made the old restriction loud instead of silent.
  This is the release that removes the restriction. See macula CHANGELOG 7.0.0.

## [0.7.0] - 2026-07-26

### Changed

- **Requires macula `~> 6.0`** (was `~> 5.1`). BREAKING for consumers, because
  macula 6.0.0 changed publish behaviour and that passes straight through:
  `macula:publish/4,5` now returns `{error, {unsupported_payload_type, Type,
  Path}}` where it previously returned `ok`, for raw floats, tuples, colliding
  map keys, out-of-range integers and oversized payloads.

  Those publishes were not working before. A float was silently rewritten as a
  six-decimal text string, and an unrepresentable term killed the shared
  peering connection while its sender was told `ok`. Services publishing raw
  floats must scale to integers (micro-units) or send binary strings.

  No wire-format change, so a service on 0.7.0 interoperates with stations and
  peers on older macula; the guard is entirely sender-side.

  See macula CHANGELOG 6.0.0.


## [0.6.0] - 2026-07-14

### Fixed

- `GET /health` is now actually served. `hecate_om_health_handler` defined the
  route but nothing ever mounted it on a listener, so `/health` was dead code
  and every hecate_om service reported unhealthy to Podman/k8s (nothing bound
  `health_port`). `hecate_om_sup` now starts a Cowboy listener on `health_port`,
  dispatching to the handler — gated on a valid `health_port`, so a service that
  wants no HTTP health endpoint simply omits the config. `snapshot/0` already
  calls the registered service's `health/0` live, so a healthy service returns
  200.

### Changed

- `macula` dependency bumped to `~> 5.1` (connect-hang fix).

## [0.5.0] - 2026-07-04

### Added

- Optional `store_integrity/0` service callback. When exported, `hecate_om:boot/1`
  threads its value (`disabled`, or `#{enabled => true, key_source => ...}`) into
  the reckon-db store config, enabling per-store HMAC event tamper-resistance.
  Defaults to `disabled` (backward compatible). `hecate_om_store:ensure/5` +
  `ensure_store/5` accept the integrity config explicitly.

## [0.4.0] - 2026-07-02

### Added
- **Optional `store_mode/0` service callback** — `single` (default) or
  `cluster`. When a service exports it, `hecate_om:boot/1` auto-starts its
  reckon-db store in that mode; `cluster` enables reckon-db discovery + Ra
  clustering so the store spans every node that starts the same `store_id`.
  New `hecate_om_store:ensure/4` + `ensure_store/4` carry the mode; the
  `/2` and `/3` arities keep defaulting to `single` (backward compatible).
  Previously the auto-started store was always `single`, with no override.

## [0.3.4] - 2026-06-24

### Fixed
- **`hecate_om_store:ensure/3` and `ensure_store/3` were not exported** in
  0.3.3, so `hecate_om:boot/1`'s cross-module call crashed with `undef` at
  boot (`{hecate_om_store_failed, ..., undef}`). The store-index wiring added
  in 0.3.3 was therefore dead on arrival. Added both to `-export`.

## [0.3.3] - 2026-06-24

### Added
- **Optional `store_indexes/0` service callback.** When a service exports it
  alongside `store_id/0` + `data_dir/0`, `hecate_om:boot/1` installs the
  returned reckon-db secondary index declarations (e.g. `{payload, Key}`,
  `{payload_hash, [Keys]}`) on the auto-started store. Previously the
  auto-wired store was created with **no** indexes, so a service that also
  declared indexes via its own `start_store` call hit `{already_started}`
  and its declarations were silently dropped — CCC payload indexes never got
  registered. `hecate_om_store:ensure/3` and `ensure_store/3` carry the index
  list; the `/2` arities delegate with `[]`.

### Changed
- Bumped the reckon-db stack pins to the current ecosystem: `reckon_db
  ~> 5.4` (was `~> 2.3` — needed for the `#store_config.indexes` field),
  `evoq ~> 1.21` (was `~> 1.15`), `reckon_evoq ~> 2.6` (was `~> 2.1`).

## [0.3.2] - 2026-06-03

### Added
- **`MACULA_STATION_SEEDS` env override for station seeds.** When set
  (comma-separated station URLs), it takes precedence over the
  `station_seeds` app env in `hecate_om_identity:configured_seeds/0`;
  empty/unset falls back to the app env. Lets one deployed image dial a
  distinct station per instance without a rebuild (e.g. one bot per node,
  one station each), matching the existing seed-via-env convention.

## [0.3.1] - 2026-06-01

### Fixed
- **Mesh connect no longer gated on the service-principal cert.**
  hecate_om_identity:attach_client/1 previously short-circuited to
  `undefined` (never calling macula:connect/2) whenever the cert file was
  absent, leaving every cert-less service permanently `no_client`. The cert
  was a spurious gate: it is never passed to `connect` (the SDK
  auto-generates an ephemeral peering identity for empty opts), only loaded
  and held for `service_cert/0` / the v2 realm-membership swap-in. Connect
  now keys off configured `station_seeds`, not cert presence.
- **Connect is deferred off the init path and retried.** At boot `hecate_om`
  could start before the macula SDK app was fully up; a single inline connect
  raced it and lost. `init/1` now schedules `self() ! connect`, retries every
  `?RECONNECT_MS` until a pool attaches, monitors the pool, and re-attaches
  if it later dies.

### Added
- Optional `identity_key_path` env: when set + loadable, the service peers
  under a stable on-disk macula-native keypair (consistent node id across
  restarts) via `#{identity => KeyPair}`; otherwise the SDK auto-generates an
  ephemeral identity. Identity is for peering, not authorization.

## [0.3.0] - 2026-05-19

### Added
- `hecate_om_store` module: canonical reckon-db + evoq wiring helper.
  Encapsulates `reckon_db_sup:start_store/1` + 30s readiness wait +
  `evoq_store_subscription:start_link/1`. The pattern documented as
  mandatory in `hecate-corpus/skills/ANTIPATTERNS_EVENT_SOURCING.md`
  now lives in one place.
- Optional callbacks on `hecate_om_service`: `store_id/0` and
  `data_dir/0`. When a service module exports both, `hecate_om:boot/1`
  auto-runs the canonical wiring before `ServiceMod:start/1`.
- New template `templates/sys.config.src.tmpl` with the canonical
  reckon_db + evoq blocks.
- `scripts/scaffold-service.sh` now renders `config/sys.config.src`
  alongside the service modules.

### Changed
- `_service.erl.tmpl` includes the optional `store_id/0` + `data_dir/0`
  callbacks by default; producer-only services remove both.
- `rebar.config` adds reckon_db, evoq, reckon_evoq as deps so services
  using `hecate_om` get the store-wiring stack for free. Producer-only
  services inherit the image-size cost but not the runtime cost
  (nothing starts unless the service module declares `store_id/0`).

### Why
Each new CMD/PRJ service was rediscovering the canonical reckon-db
wiring (or, more often, missing pieces of it). The parksim trio
shipped without `{evoq, [{event_store_adapter, ...}]}` and without
any `reckon_db_sup:start_store/1` call, leaving evoq in default
in-memory mode despite being configured as event-sourced. This
release moves the pattern into the library so future services pick
it up just by exporting two callbacks.

## [0.2.0]

### Added
- Initial scaffold: `hecate_om_service` behaviour, helpers for
  identity claim, capability advertise, and `/health` endpoint.
- Templates for `Containerfile`, Quadlet unit, `manifest.json`, and
  CI workflow.
- Guides: service anatomy, identity model, container deployment.

### Planned
- UCAN-delegated identity wiring once `hecate-realm` issues service
  principals
- Common Test framework helpers for service test suites

## [0.1.0] - YYYY-MM-DD

_Not yet released._
