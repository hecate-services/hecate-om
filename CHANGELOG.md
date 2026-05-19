# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-05-19

### Added
- `hecate_om_store` module: canonical reckon-db + evoq wiring helper.
  Encapsulates `reckon_db_sup:start_store/1` + 30s readiness wait +
  `evoq_store_subscription:start_link/1`. The pattern documented as
  mandatory in `hecate-agents/skills/ANTIPATTERNS_EVENT_SOURCING.md`
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
