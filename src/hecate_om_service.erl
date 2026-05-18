%%% @doc The behaviour every hecate-service implements.
%%%
%%% Six callbacks, no more. Everything else (release packaging,
%%% container image, Quadlet unit, manifest, health wiring,
%%% capability advertisement) is handled by the rest of hecate_om
%%% and by the templates in `templates/`.
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
