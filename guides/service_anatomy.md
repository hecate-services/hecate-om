# Anatomy of a hecate-service

A Hecate service is one OTP release and one OCI container, running on
an infrastructure node rather than on a user's laptop. A laptop is a
citizen: it consults services across the mesh, it does not host them.

`rebar3 new hecate_service` generates the whole layout below; see the
README for how to install the template.

## Repository layout

```
<org>/hecate-X/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── Containerfile                ← multi-stage Erlang build
├── rebar.config                 ← deps incl. {hecate_om, "~> 0.9"}, relx release
├── apps/hecate_x/
│   ├── src/
│   │   ├── hecate_x.app.src     ← `applications: [hecate_om, …]`
│   │   ├── hecate_x_app.erl     ← `start/2 -> hecate_om:boot(hecate_x_service)`
│   │   ├── hecate_x_sup.erl
│   │   └── hecate_x_service.erl ← implements hecate_om_service
│   └── test/
│       └── hecate_x_service_tests.erl
├── config/
│   ├── sys.config.src           ← realm, health port, station socket
│   └── vm.args.src
├── deploy/
│   └── docker-compose.yml       ← how to run it
├── scripts/
│   └── health.sh
└── .github/workflows/
    ├── lint.yml                 ← rebar3 lint + eunit
    └── build-push.yml           ← image publish on main + tags
```

A service that grows vertical slices adds them as further apps under
`apps/`, one per capability, CMD / PRJ / QRY as the domain requires.

## Lifecycle

```
the container runtime pulls <registry>/<org>/hecate-X:latest
   ↓
Erlang VM boots → application:start(hecate_x)
   ↓
hecate_x_app:start/2 → hecate_om:boot(hecate_x_service)
   ↓
hecate_om:
   ├── loads the service-principal cert from
   │   /etc/hecate/secrets/service-cert.pem (a mounted volume)
   ├── registers capabilities() into hecate_om_capabilities
   ├── registers the service module into hecate_om_health
   ├── wires a reckon-db store IF the service exports store_id/0
   │   and data_dir/0; producer-only services pay nothing
   ├── (planned) auto-rotates short-lived UCANs against hecate-realm
   └── calls hecate_x_service:start(Opts) → hecate_x_sup:start_link()
   ↓
hecate_om_capabilities:publish/0 announces capabilities on the mesh
   ↓
GET /health ready to answer, on the port sys.config.src was given
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

## Store-backed services (optional)

A CMD/PRJ service that owns a `reckon-db` event store exports three more
**optional** callbacks. When both `store_id/0` and `data_dir/0` are present,
`hecate_om:boot/1` auto-wires the store and its evoq subscription during
`maybe_wire_store`, *before* `start/1` runs — so the store is already up
when your supervisor boots. You never call `reckon_db_sup:start_store/1`
directly.

```erlang
-export([store_id/0, data_dir/0, store_indexes/0]).

store_id()   -> my_service_store.            %% atom; data at <data_dir>/<store_id>/
data_dir()   -> "/var/lib/hecate-my-service".

%% reckon-db secondary indexes installed on the auto-started store. This is
%% the ONLY place CCC payload indexes get declared for an auto-wired store —
%% declaring them in your own start/1 is too late (the store is already up,
%% so start_store returns {already_started} and your indexes are dropped).
store_indexes() ->
    [tags, event_type,
     {payload, <<"plate">>},
     {payload_hash, [<<"lot_id">>, <<"plate">>]}].
```

`store_indexes/0` is itself optional — omit it (or return `[]`) for a store
with no secondary indexes. Boot threads its result into the `#store_config{}`
so `reckon_db_index_config` registers the declarations; the gateway's CCC
payload/hash queries then resolve against them. Requires `hecate_om >= 0.3.4`.

Boot order with a store:

```
hecate_X_app:start/2 → hecate_om:boot(hecate_X_service)
   ↓
hecate_om:maybe_wire_store/1   (store_id/0 + data_dir/0 present?)
   ├── reckon_db_sup:start_store(#store_config{indexes = store_indexes()})
   └── evoq_store_subscription:start_link(store_id())
   ↓
hecate_X_service:start/1 → hecate_X_sup:start_link()   (store already up)
```

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
