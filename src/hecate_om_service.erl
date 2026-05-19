%%% @doc The behaviour every hecate-service implements.
%%%
%%% Six required callbacks + two optional ones for CMD/PRJ services
%%% that own a reckon-db store. Everything else (release packaging,
%%% container image, Quadlet unit, manifest, health wiring,
%%% capability advertisement) is handled by the rest of hecate_om
%%% and by the templates in `templates/`.
%%%
%%% When a service exports the optional `store_id/0` + `data_dir/0`
%%% callbacks, `hecate_om:boot/1` will, before calling
%%% `ServiceMod:start/1`:
%%%
%%%   - `reckon_db_sup:start_store/1` with a `single`-mode store at
%%%     `<data_dir>/<store_id>/`,
%%%   - wait up to 30s for the store to appear in
%%%     `reckon_db_sup:which_stores/0`,
%%%   - `evoq_store_subscription:start_link/1` so projections + PMs
%%%     receive events.
%%%
%%% Producer-only services (no event store) simply omit both
%%% callbacks. See `hecate_om_store` for the helper module.
-module(hecate_om_service).

-type info()           :: #{name := binary(), version := binary(), description := binary()}.
-type health()         :: ok | {degraded, term()} | {down, term()}.
-type capability()     :: #{name := binary(), version := pos_integer()}.
-type identity_spec()  :: #{scope := binary(),
                            actions := [binary()],
                            resources := [binary()],
                            ttl_days := pos_integer()}.

-export_type([info/0, health/0, capability/0, identity_spec/0]).

%% @doc Static metadata about the service. Reported on /health.
-callback info() -> info().

%% @doc Start the service's supervision tree. Called once on boot.
-callback start(map()) -> {ok, pid()} | {error, term()}.

%% @doc Stop the service. Called on shutdown.
-callback stop(term()) -> ok.

%% @doc Snapshot of current health. Called every /health hit.
-callback health() -> health().

%% @doc Capabilities this service exposes, to be advertised on the
%% mesh. Other services find this one by these names.
-callback capabilities() -> [capability()].

%% @doc UCAN this service wants minted by hecate-realm at boot.
%% Until UCAN-delegation lands in realm, this is informational only.
-callback identity_spec() -> identity_spec().

%% @doc OPTIONAL. The reckon-db store_id this service owns. When
%% exported alongside `data_dir/0`, hecate_om:boot/1 auto-starts
%% the store and the per-store evoq subscription before the
%% service module's own start/1 fires.
-callback store_id() -> atom().

%% @doc OPTIONAL. The on-disk root for this service's reckon-db
%% store. The store data lands at `<data_dir>/<store_id>/`.
-callback data_dir() -> string().

-optional_callbacks([store_id/0, data_dir/0]).
