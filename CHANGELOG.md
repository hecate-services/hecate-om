# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [0.16.2] - 2026-08-31

### Fixed

- **Second silent-failure path in the same area as 0.16.1**:
  `advertise_with/7`'s fallback clause (pool/keypair/realm not all ready)
  had NO logging at all -- worse than 0.16.1's bug, since that one at
  least implies `advertise_direct` got called. This clause's own comment
  assumed a "transient mesh gap" resolved within a few republish ticks;
  a genuinely stuck pool or identity means this clause fires forever,
  silently, with capabilities never advertised and nothing anywhere to
  say why. Deployed 0.16.1 to `hecate-stations` (beam03) specifically to
  observe this in production and found exactly this: 0.16.1's new
  logging never fired at all, and `hecate_stations.list_stations` still
  wasn't in the DHT (confirmed via `macula-cli dht find-records-by-type`)
  -- meaning the failure was happening one level earlier than 0.16.1
  could see.
  Now logs the specific reason for each of pool/keypair/realm
  (`hecate_om_capabilities: advertise skipped, not all of pool/keypair/
  realm are ready yet: {PoolError, KeyPairError, RealmError}`), throttled
  to once per distinct reason triple (a process-dictionary-scoped gate)
  so a persistent boot problem doesn't spam a warning every 30s forever.
  30/30 capabilities tests + 82/82 full suite pass, dialyzer clean.

## [0.16.1] - 2026-08-31

### Fixed

- **Silent advertise failures**: `hecate_om_capabilities:advertised/3`
  discarded `advertise_direct`'s `{error, Reason}` outright, and
  `put_advertisement/2`'s `try ... catch _:_ -> ok end` discarded BOTH a
  plain `{error, _}` return from `macula:put_record/2` (never pattern-matched
  at all, not just the exception guard) and any real exception, all with no
  logging anywhere. Combined with `register/1`'s `handle_call` always
  replying `ok` regardless of what `do_advertise` actually did, a service
  could run "healthy" indefinitely with its capability never actually
  reaching the mesh's DHT and nothing anywhere to indicate why. Also a
  correctness gap against this repo's own CLAUDE.md: a `try/catch` here is
  only justified when it adds monitoring value neither branch did.
  Both paths now `logger:warning/2` the real reason
  (`hecate_om_capabilities: advertise_direct for ~s failed: ~p` /
  `... put_record (record-only advertisement) failed: ~p`). Found live
  investigating why `hecate_stations.list_stations` was unreachable
  through the mesh: confirmed via `macula-cli dht find-records-by-type`
  that its advertisement genuinely never reached the DHT, but nothing in
  the service's own logs said why until this fix — existing tests already
  exercise the failure path and now show a real reason (`no_healthy_station`
  in the test fixture's case) instead of silence. 30/30 existing tests
  still pass.

## [0.16.0] - 2026-08-29

### Fixed

- **Shared-station capability dispatch**: two orgs advertising the same bare
  capability name from the same relay station collided on
  `macula_remote_advertise_registry`'s single-provider-per-bare-name
  invariant — whichever org's 30s republish landed last silently answered
  every targeted `call_capability`, regardless of `Org`. `advertise_one/7`
  now makes two independent `advertise_direct` registrations per
  handler-bearing capability (bare name, plus `Org/Name` as a genuinely
  distinct wire-level registration); `resolve_full/4` tags each resolved
  provider with the wire-level procedure string that actually matched, and
  `call_capability` CALLs with that string, not the raw capability name.
  Live-verified against `station-de-frankfurt.macula.io`.
- `find/2`'s DHT resolution had no retry margin against write-propagation
  lag, unlike `macula_direct_dial`'s own internal resolution — mirrored its
  retry budget (50 x 100ms).
- Advertisements now carry a `ttl_ms` proportioned to the 30s republish
  interval instead of the ~48h envelope default, live effect confirmed
  after bumping the `macula` dependency past the `adv_opts/1` fix below.

### Added

- `list_org_capabilities/1` / `resolve_org_capabilities/3` — browse every
  capability an org has advertised, without knowing any capability name in
  advance. Client-side filter over `macula:find_records_by_type/2`
  (matched via `macula`'s new `macula_topic_pattern`), same local-relay-view,
  warm-start-only semantics `read_model_services.md` already documents for
  that call.

### Changed

- Bumped `macula` dependency 10.10.0 -> 10.13.1: `macula_direct_dial:adv_opts/1`
  no longer silently drops `ttl_ms`; `macula_client`'s connection pool no
  longer dials a redundant duplicate connection to a station it already
  holds a live link to under a different seed spelling (was reproducible,
  live, as literally the second `call_station` from one pool to the same
  station); `macula_topic_pattern` and station-local wildcard pubsub
  subscriptions added. See macula's own CHANGELOG [10.11.1]-[10.13.1].

## [0.15.1] - 2026-08-27

### Fixed

- Bumped `macula` dependency 10.0.0 -> 10.10.0. Had drifted 10 releases
  behind the fleet (currently 10.10.0), including the domain-filter fix
  that was silently dropping every `macula_diagnostics:event/2,3` call
  on any consumer of this library (see macula CHANGELOG [10.10.0]).
  Confirmed no use of anything removed in 10.0.0's macula-net deletion;
  full eunit + CT suite clean at the new version.
- `rebar3 dialyzer` failed the release gate with 3 "Callback info about
  the X behaviour is not available" warnings (macula_publisher,
  macula_feeder, macula_download) — confirmed pre-existing at macula
  10.0.0 too, not caused by the bump above. Root cause: `exclude_apps`
  drops `macula` from the PLT entirely (it ships without `debug_info`,
  a NIF-heavy lib, which otherwise hard-fails dialyzer), so the three
  behaviours this module implements have no callback info to check
  against. `no_unknown` doesn't cover this — the warning is tagged
  `?WARN_UNDEFINED_CALLBACK` internally (`dialyzer_behaviours.erl`),
  not `?WARN_UNKNOWN`, and `no_behaviours` (`?WARN_BEHAVIOUR`) is also
  the wrong option, verified against dialyzer 5.4's own source before
  picking `no_undefined_callbacks`. Clean run confirmed on a fully
  fresh PLT.

## [0.15.0] - 2026-08-24

### Added

- `read_model_id/0` optional `hecate_om_service` callback (alongside
  `data_dir/0`): `hecate_om:boot/1` opens a `barrel_docdb` database at
  `<data_dir>/<read_model_id>/` before the service's own `start/1` runs,
  the same shape as the existing `store_id/0` reckon-db wiring but for a
  persistent, queryable read model instead of an event store. New
  `hecate_om_read_model:ensure/2` helper, new `hecate_om:read_model/0`
  facade accessor. `barrel_docdb` is now a hard dependency (same "everyone
  pays, only starts if declared" shape as reckon_db/evoq — note this one
  carries a real native build cost too, rocksdb's C++ library, not a free
  dep). Only `barrel_docdb`, not the full `barrel`/`barrel_vectordb`
  umbrella; a service that wants vector or hybrid search in its read model
  adds that itself. Meant to replace the class of bug where an ETS-backed
  read model silently loses its contents on every restart (see
  hecate-spartan's registry/inbox history) — barrel_docdb reopens from its
  on-disk RocksDB directory, nothing to rebuild.

## [0.14.2] - 2026-08-23

### Fixed

- Self-healed keypairs are now puzzle-hardened (`macula_identity:generate(#{puzzle => true})`),
  mirroring macula-realm's own mesh identity. Every station in this fleet
  enforces S/Kademlia puzzle validation on CONNECT/HELLO; a plain identity's
  handshake completes and is then closed with `puzzle_invalid` — a graceful
  drain, then `drained` — on every single connection, forever. Confirmed
  live: this is the full explanation for why `tube_mesh_providers` could
  report `advertised => true` (its own local, client-side bookkeeping)
  while no station's DHT-facing advertise registry ever actually held the
  advertisement — a ~96-second reject/reconnect loop, invisible until the
  underlying station logged its disconnect reason at all (a separate fix,
  `macula-station` `4188a1d`).

## [0.14.1] - 2026-08-23

### Fixed

- `hecate_om_identity`'s stable keypair now self-heals instead of silently
  staying unconfigured. `load_keypair/0` previously only ever *loaded* from
  `identity_key_path` — a service deployed with the env pointed at a path
  with nothing there yet (the common case: nobody's provisioned it
  out-of-band) got `keypair() -> {error, no_keypair}` forever, every single
  boot, with no error logged anywhere. Confirmed live on hecate-tube: its
  `tube_mesh_providers` retries advertising `tube.watch_video_clip` /
  `tube.lookup_channel` / `tube.lookup_video_clip` every 5s pending both
  `mesh_handles/0` and `keypair/0` — `mesh_handles/0` resolved fine (the
  service peers and calls just fine on an ephemeral identity), `keypair/0`
  never did, so the service silently never advertised any of its three
  direct-dial providers, ever, since its first deployment. No amount of
  local testing catches this — it only surfaces against a real deployment
  that actually tries to be *called*, not just to call out.

  Now: any load failure (missing file — the common case — or a corrupt
  one) generates a fresh keypair via `macula_identity:generate/0` and
  persists it to the configured path via `macula_identity:save/2` (which
  `ensure_dir`s it), same self-provisioning pattern macula-realm's own mesh
  identity already uses. Falls back to `undefined` (ephemeral, prior
  behavior) only if the save itself fails, e.g. a read-only filesystem.
  `identity_key_path` left unconfigured is unaffected — still ephemeral by
  design, unchanged.

## [0.14.0] - 2026-08-22

### Added

- `hecate_om:mesh_handles/0` — the shared `{Pool, Realm}` fetch every
  PubSub/RPC-consumer/Content call needs together, replacing the hand-rolled
  `case {macula_client(), realm()} of {{ok,P},{ok,R}} -> ...` pairing four
  independent hecate-services repos each wrote for themselves because
  hecate_om gave them nothing to build on.
- `hecate_om:realm/0` and `hecate_om:keypair/0` — re-exported on the public
  facade. Both already existed on `hecate_om_identity`; a service previously
  had to reach past the facade to get them. `keypair/0` is needed by every
  direct-dial PROVIDER desk (`macula_response:advertise_direct/6,7`,
  `macula_streamer:advertise_direct/6,7`, ...), which sign their own DHT
  advertisement record with it.

### Changed

- Bumped macula dependency `~> 9.0` → `~> 10.0`. macula 10.0.0 removed the
  dormant macula-net L3 substrate; grepped `src/`/`include/` first —
  hecate-om never called any of it. Verified against a genuine fresh fetch
  off hex (not a local checkout): clean compile, 13/13 eunit.
- Bumped macula dependency to `~> 9.0`, pulling in direct-dial across all
  four SDK primitive pairs (RPC/PubSub/Content/Streaming).
- Slice 7c verify switched to **Direction B** (managed-realm X.509 cert chain),
  replacing the Ed25519 delegation-record chain that could never go live (the realm
  tag is a keyless `SHA-256(name)` and the realm holds no signing key). Requires
  macula `~> 8.7`.
  - Advertise: `hecate_om_capabilities:build_advertisement/6` embeds the service's
    cert chain (leaf ++ org CA) in the `procedure_advertisement`, from
    `hecate_om_identity:cert_chain/0`. Services with no provisioned chain advertise
    without one (open-mode only).
  - Verify: under `verify => true`, providers are kept only if their embedded chain
    verifies to the realm CA (`macula_record:verify_advertisement_cert_chain/3`,
    org-scoped) instead of resolving `org_directory` / `procedure_delegation`
    records. No realm CA provisioned → every provider dropped.
  - `hecate_om_identity` loads the org CA (`org_ca_cert_path`, default
    `/etc/hecate/secrets/org-ca.pem`) and realm CA (`realm_ca_cert_path`, default
    `/etc/hecate/secrets/realm-ca.pem`); exposes `cert_chain/0` and `realm_ca/0`.

### Fixed

- `priv/templates/hecate_service/rebar.config` pinned `{hecate_om, "~> 0.8"}`,
  six major versions stale — every service scaffolded via `rebar3 new
  hecate_service` inherited it. Now `~> 0.13`.

## [0.13.0] - 2026-08-19

### Added

- Slice 7c consumer side + org-namespaced addressing:
  - Capabilities are addressed by `(realm, org, name)`: `procedure_uri/3` and the
    advertisements carry the `<org>` segment. `hecate_om_identity:org/0` reads the
    `org` app env (default `<<"_">>`).
  - `hecate_om:call_capability/4` `(Org, CapName, Payload, Timeout)` and
    `hecate_om_capabilities:call_capability/5` with `Opts`: `verify => true` drops
    providers whose realm → org → server delegation chain does not verify (7c);
    `ucan_token => Bin` presents a token to a gated provider (7b). Default is open
    (no verify, no token).

### Changed

- Requires macula `~> 8.6`, which also FIXES capability publishing. SDK
  `put_record` of a `procedure_advertisement` crashed the station's store handler
  on wire-decoded records before macula 8.6.0 (it had only been exercised via
  direct erpc puts). On this release publishing works end-to-end.

### Note

- The verifying-consumer path (`verify => true`) needs the realm and org to have
  published `org_directory` / `procedure_delegation` records (realm/org
  infrastructure, not the service). Until that exists, use the default open mode;
  the verification mechanism is proven in macula-station's delegation e2e.

## [0.12.0] - 2026-08-19

### Added

- `hecate_om:call_capability/3` — call a capability by name over the direct-dial
  data path: resolve a provider from the DHT (`procedure_advertisement`), resolve
  its serving station to a dialable endpoint (`station_endpoint`), dial it directly
  and CALL the raw `CapName` there, failing over to the next provider on error.

### Fixed

- Capability RESOLUTION now works over the real SDK path. On macula 8.2.0-8.4.0 a
  consumer resolving via `find_records/2` got `undefined` fields (the record
  readers did not handle the atomised payload keys the SDK path returns), so
  discovery silently returned no usable providers. macula 8.4.1 fixes the readers.

### Changed

- Requires macula `~> 8.4` (was `~> 8.2`): `call_station` + `station_endpoint`
  readers (8.3.0), TLS-policy forwarding (8.4.0), and the reader atom-key fix
  (8.4.1).

## [0.11.0] - 2026-08-19

### Changed

- **Capability discovery is now DHT record-based, replacing the pubsub
  `_mesh.cap.announce` broadcast.** On capability register (and a 30s republish
  tick) a service writes one signed `procedure_advertisement` per capability to
  the mesh DHT (advertiser = the service's key, serving_station = a connected
  station, procedure_uri = realm-namespaced capability name). `lookup/1` resolves
  by reading those records via `macula:find_records/2`, verifying each signature,
  and returns `{ok, [#{advertiser, serving_station}]}` — a consumer then dials one
  of those stations directly (direct-dial discovery, no multi-hop).
- **Requires macula `~> 8.2`** (was `~> 8.0`): uses `find_records/2`,
  `read_procedure_advertisement/1`, `procedure_key/1` from macula 8.2.0.

### Added

- `hecate_om_identity:keypair/0` — the service's retained stable signing keypair,
  or `{error, no_keypair}` for an ephemeral service (which is then not advertised
  and stays invisible to DHT discovery, by design).

### Removed

- The pubsub `_mesh.cap.announce' publish/subscribe path and `peers/0`. There
  were no callers of the old `lookup/1' summary shape.

## [0.10.0] - 2026-08-13

### Changed

- **Requires macula `~> 8.0`** (was `~> 7.0`). This is the release that lets a
  hecate-om service say WHY it refused.

  macula 8.0.0 stopped answering `{error, {call_error, 16#0F, unknown_error}}`
  when a handler returns `{error, Reason}` and now returns the handler's own
  reason. `0x0F` is the code the SDK stamps when a handler says no, so it never
  meant "unknown error" in practice — it meant a service had refused and could
  not tell you why. Every refusal in the world arrived as the same three words.

  ```erlang
  %% handler
  handle(_) -> {error, <<"hold_full">>}.

  %% caller, on 7.x
  {error, {call_error, 15, unknown_error}}
  %% caller, on 8.x
  {error, <<"hold_full">>}
  ```

  Measured rather than assumed: a two-service torture across two live stations
  with no direct edge fails this on 7.0.0 with exactly the old constant and
  passes on 8.0.0 with the reason intact.

  **Consumer impact.** Nothing in this library matches the old shape — there is
  no `call_error` or `unknown_error` anywhere in `src/`, `priv/` or `test/`. A
  consumer that pattern-matches `{error, {call_error, _, _}}` on a REFUSAL will
  stop matching; one that matches `{error, _}` is unaffected. Transport failures
  keep the `{call_error, Code, Name}` shape, so only the handler-refusal case
  changes.

  ⚠ A binary reason now crosses the wire verbatim; non-binary reasons arrive as
  printed binaries. See macula CHANGELOG 8.0.0.

### Added

- **`store` variable on `rebar3 new hecate_service`, off by default.** Empty
  generates a storeless service exactly as before, which is what most services
  want. `store=1` generates the whole thing at once: `store_id/0` and
  `data_dir/0`, a store named `<name>_store`, the `evoq` adapter block in
  `config/sys.config.src`, a data volume and `HECATE_DATA_DIR` in the compose
  file, and three boundary guards keeping them in step.

  It exists because adding a store by hand is **three** things and not one, and
  omitting the third crash-loops the node before any service code runs. A sibling
  service put two of three fleet nodes into a boot loop by exporting the
  callbacks without adding the `evoq` block, which raises
  `{not_configured, event_store_adapter}` at release boot. The generated README
  says the same thing in both branches, so a service scaffolded without a store
  is told what adding one really costs.

  ⚠ **The value must be exactly one character, so `1` and not `yes`.** rebar3
  passes template variables as strings and mustache iterates a string as a list,
  so a longer value repeats every conditional block once per character. That is a
  limitation of the template engine rather than a preference, it is documented on
  the variable itself, and it fails loudly at the first `rebar3 compile` with
  `spec for store_id/0 already defined` rather than shipping anything.

- **The generated suite now checks that the two OTP pins agree, and that you are
  running what they name.** `rebar3 new hecate_service` has always pinned the
  release in two files, the `Containerfile` and `.github/workflows/lint.yml`, and
  0.9.0's own commit message said they must agree. Nothing enforced it.

  A sibling service shipped with its `Containerfile` on 27 while development ran
  on 28, so a local `rebar3 eunit` meant "passing on 28" and nothing more, CI
  failed for three commits on a crash that does not occur on 28 at all, and
  because the image build is a separate workflow the image reached the fleet
  regardless.

  The generated `*_service_tests.erl` now reads both files and compares them
  against `erlang:system_info(otp_release)`. **It fails rather than warns when
  the running VM differs**, because developing on a release you do not ship makes
  a green suite mean less than it appears to. Moving to another release means
  moving both pins, which is the point of having them.

  No change to `src/`.

### Fixed

- **README no longer claims services never run on user laptops.** It said
  Layer-2 services "run on realm infrastructure nodes ... not on user
  laptops. They are institutions, not user agents", in the opening
  paragraph and again in the layering diagram. That is a deployment
  policy for the realm's own shared services, stated as if it were a
  property of this substrate, and it is the wrong way round: a hecate-om
  service is **edge-first**. It dials out to a `macula-station` over
  QUIC, needs no inbound port and no public address, and reaches its
  peers through the station. Running one on a laptop is the ordinary
  case, not an exception.

  What the sentence was reaching for is the identity rule, which stands
  and is now stated on its own: a service answers with its own
  service-principal credential chaining to a realm root, never as the
  human whose machine it runs on. Placement is a deployment decision;
  identity is not.

  No change to `src/`.

## [0.9.0] - 2026-07-31

No change to `src/`. This release is the scaffold, its guard, and a
documentation pass; consumers of the library itself get the same behaviour
they had on 0.8.0.

### Added

- **`rebar3 new hecate_service`**, a real rebar3 template in `priv/templates`,
  generating a repository that compiles, tests and deploys: the OTP application
  and supervisor, the six-callback service module, a eunit suite asserting the
  contract, a relx release, a `Containerfile`, both CI workflows, an executable
  `scripts/health.sh`, `deploy/docker-compose.yml`, and the usual documentation.
- `scripts/install-templates.sh`, because rebar3 only finds custom templates
  under `~/.config/rebar3/templates` and an empty directory has no dependency to
  carry them there.
- `hecate_service_template_SUITE`, which generates a service for real through
  `rebar3 new` and then compiles it against this library, so the
  `-behaviour(hecate_om_service)` attribute checks all six callbacks. It also
  asserts the file set, that `health.sh` is executable, that no unrendered
  variable survives, and that GitHub Actions expressions are intact.
- `.github/workflows/lint-and-test.yml`. This repository had no CI at all, which
  is how the old templates drifted unnoticed.

### Changed

- **`scripts/scaffold-service.sh` is now a wrapper over the template** and takes
  the service name once, deriving the snake_case application name from the
  kebab-case repository name. It previously rendered a handful of files with sed
  and left you to write `rebar.config`, the `.app.src` and the supervisor by
  hand, so a scaffolded service did not compile.

### Fixed

- The hex package links and the ex_doc `source_url` pointed at Codeberg.
  GitHub has been canonical since 2026-07-26.
- `guides/container_deployment.md` described a deployment that does not exist:
  system-wide Podman Quadlets reconciled by `hecate-gitops`, a
  `hecate-realm-admin` CLI, a loopback-published health port. It referenced
  three template files that no longer exist. Rewritten to describe what the
  generated service actually does, with a closing section naming what is
  intended rather than built.
- `guides/service_anatomy.md` showed a repository layout with `quadlet/`, a
  `manifest.json` and a flat `src/`, none of which the scaffold produces.
- The README's status line claimed v0.5.0.

### Removed

- **The old `templates/` directory.** It had drifted from the estate it was
  meant to serve: a Quadlet unit that nothing on the fleet uses (the beam nodes
  run docker compose under a pull-based reconciler), `TODO` comments in place of
  two callbacks, a store-backed service as the default in a mostly producer-only
  estate, an `identity_spec` claiming two actions and a wildcard resource for a
  service that could exercise none of them, and no test file at all. Nothing
  consumed it: the `hecate-om scaffold` CLI its own README documented was never
  written.

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
