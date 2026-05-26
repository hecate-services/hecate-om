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
