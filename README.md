# hecate-om

**Hecate-over-mesh**: the shared substrate every `hecate-services/hecate-X`
service daemon stands on.

Services in this org run on **realm infrastructure nodes** (the BEAM
cluster, dedicated relay boxes, cooperative-contributed service
nodes), not on user laptops. They are institutions, not user agents
— see [`guides/identity_model.md`](guides/identity_model.md) for the
town/library metaphor that drives the identity choices.

```
                        hecate-om
                            │
        ┌──────────┬────────┼─────────┬──────────┬─────────┐
        ▼          ▼        ▼         ▼          ▼         ▼
   hecate-rag  hecate-llm hecate-dns hecate-git hecate-blob …
```

Every service is a separate OTP release shipped as an OCI container
to `ghcr.io/hecate-services/`. `hecate-om` is the library they all
link against to behave consistently on the mesh: the same service
contract, the same manifest schema, the same health endpoint, the
same identity-claim flow, the same capability-advertise pattern, the
same Containerfile + Quadlet templates.

## What this library is (and isn't)

It **is**:

- An Erlang `behaviour` (`hecate_om_service`) — six callbacks every
  service implements: `start/1`, `stop/1`, `health/0`, `capabilities/0`,
  `identity_spec/0`, `info/0`.
- Helpers for the bits every service needs: load the realm cert,
  advertise a capability via macula's bloom-channel, serve a `/health`
  endpoint, parse the standard `manifest.json` schema.
- Mustache templates for the boilerplate every service repo carries:
  `Containerfile`, `quadlet/<service>.container`, `manifest.json`,
  `release_template`.

It **is not**:

- A daemon. It has no `application:start_phase` of its own beyond
  the library's facade.
- A plugin host. Services are containerised. Plugins live in
  `hecate-daemon` (different repo, different model).
- A network library. Services talk to `macula-station` via the
  macula SDK like any other Macula client.

## Layering position

```
Layer 4 — apps        hecate-app-martha, hecate-app-rag (UI), …
                      User-facing plugins, live in hecate-daemon

Layer 3 — session     hecate-daemon
                      Per-identity, plugin host, UI surface

Layer 2 — services    hecate-services/hecate-rag, -llm, -dns, -git, …
                      Always-on, containerised, system-class workloads.
                      Run on realm infrastructure nodes (BEAM cluster,
                      relay boxes), never on user laptops.
                      ↑↑↑ this library is the substrate ↑↑↑

Layer 1 — identity    hecate-realm / macula-realm

Layer 0 — kernel      macula-station
```

See [`philosophy/HECATE_TIER_MODEL.md`](https://codeberg.org/hecate-social/hecate-corpus/src/branch/main/philosophy/HECATE_TIER_MODEL.md)
in hecate-corpus for the longer cut-criteria discussion.

## The contract

```erlang
-module(my_service).
-behaviour(hecate_om_service).

%% lifecycle
-export([start/1, stop/1]).

%% introspection
-export([health/0, capabilities/0, identity_spec/0, info/0]).

start(_Opts) ->
    my_service_sup:start_link().

stop(_State) ->
    ok.

%% Reported on /health endpoint. Return ok | {degraded, Reason} | {down, Reason}.
health() ->
    ok.

%% Advertised onto the mesh via hecate_om_capabilities:advertise/1.
%% Other services / plugins find you by these.
capabilities() ->
    [
        #{name => <<"my_service.do_thing">>, version => 1},
        #{name => <<"my_service.list_things">>, version => 1}
    ].

%% Tells hecate-realm what UCAN this service needs.
identity_spec() ->
    #{
        scope     => <<"my_service">>,
        actions   => [<<"publish_summary">>, <<"answer_query">>],
        resources => [<<"my_service/*">>],
        ttl_days  => 30
    }.

info() ->
    #{
        name        => <<"hecate-my-service">>,
        version     => <<"0.1.0">>,
        description => <<"What this service does in one line">>
    }.
```

That's the whole user-side contract. Six small functions. Everything
else (release tarball, container image, Quadlet unit, manifest, health
endpoint wiring, mesh advertisement) is provided by `hecate-om` + the
template generators in `templates/`.

## Optional: store-backed services

CMD/PRJ services that own a `reckon-db` event store export three more
**optional** callbacks. When a service exports `store_id/0` + `data_dir/0`,
`hecate_om:boot/1` auto-starts the store and its evoq subscription *before*
`start/1` runs — you never call `reckon_db_sup:start_store/1` yourself.
Producer-only services (no store) omit these and pay nothing.

```erlang
%% Optional store-wiring callbacks (only if the service owns a store)
-export([store_id/0, data_dir/0, store_indexes/0]).

%% Atom store id. Data lands at <data_dir>/<store_id>/.
store_id() -> my_service_store.

data_dir() -> "/var/lib/hecate-my-service".

%% reckon-db secondary index declarations installed on the store. This is
%% how CCC payload indexes get declared — without it the store starts with
%% no secondary indexes and payload/hash queries find nothing.
store_indexes() ->
    [tags, event_type,
     {payload, <<"plate">>},                            %% single-field index
     {payload_hash, [<<"lot_id">>, <<"plate">>]}].      %% composite hash index
```

`store_indexes/0` is itself optional: export it only when the store needs
secondary indexes. Omit it (or return `[]`) for a store with none.

> Requires `hecate_om >= 0.3.4`. (0.3.3 introduced the callback but failed
> to export the helper it calls, crashing boot — use 0.3.4+.)

## Scaffold a new service

```bash
# Inside a fresh hecate-services/hecate-NEWSERVICE checkout:
hecate-om scaffold --name hecate-newservice --description "Does X over the mesh"
```

Generates:
- `src/hecate_newservice.app.src` and `*_app.erl`, `*_sup.erl`
- A skeleton `*_service.erl` implementing the behaviour
- `Containerfile` (multi-stage Erlang build)
- `quadlet/hecate-newservice.container`
- `manifest.json` (service_type: container_daemon)
- `.github/workflows/build-push.yml` (build + push to ghcr.io)
- `rebar.config` (with hecate_om as dep)

(The `hecate-om scaffold` CLI is a follow-up. Today, copy
`templates/` and find-replace `newservice` manually.)

## Status

**Scaffold.** Behaviour declared; helpers stubbed; templates drafted.
No runtime testing yet. First consumer will be `hecate-services/hecate-rag`
when we extract the RAG daemon from `hecate-app-rag`.

## License

Apache-2.0. See [LICENSE](LICENSE).
