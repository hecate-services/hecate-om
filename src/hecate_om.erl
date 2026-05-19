%%% @doc Public facade for hecate-om.
%%%
%%% Services typically only need a handful of these:
%%%
%%%   hecate_om:boot(MyServiceMod)         %% one-call lifecycle wiring
%%%   hecate_om:advertise_capabilities()   %% (re-)publish my caps
%%%   hecate_om:health()                   %% snapshot for /health
%%%   hecate_om:service_cert()             %% load my service-principal cert
%%%   hecate_om:macula_client()            %% returns the SDK client handle
-module(hecate_om).

-export([
    boot/1,
    boot/2,
    advertise_capabilities/0,
    health/0,
    service_cert/0,
    macula_client/0,
    service_module/0
]).

-define(SERVICE_MODULE_KEY, hecate_om_service_module).

%% @doc Wire a service module into hecate_om and start it.
%%
%% Typical call from the hosting service's `_app:start/2`:
%%
%%   start(_, _) ->
%%       hecate_om:boot(my_service).
-spec boot(module()) -> {ok, pid()} | {error, term()}.
boot(ServiceMod) ->
    boot(ServiceMod, #{}).

-spec boot(module(), map()) -> {ok, pid()} | {error, term()}.
boot(ServiceMod, Opts) when is_atom(ServiceMod), is_map(Opts) ->
    persistent_term:put(?SERVICE_MODULE_KEY, ServiceMod),
    ok = maybe_wire_store(ServiceMod),
    ok = hecate_om_capabilities:register(ServiceMod:capabilities()),
    ok = hecate_om_health:register(ServiceMod),
    ServiceMod:start(Opts).

%% @private When the service module exports both `store_id/0` and
%% `data_dir/0`, treat it as a CMD/PRJ service that owns a reckon-db
%% store. Wire the canonical pattern before the service's own
%% start/1 runs. Producer-only services omit the callbacks and pay
%% nothing.
maybe_wire_store(ServiceMod) ->
    _ = code:ensure_loaded(ServiceMod),
    Has = erlang:function_exported(ServiceMod, store_id, 0) andalso
          erlang:function_exported(ServiceMod, data_dir, 0),
    case Has of
        false -> ok;
        true ->
            StoreId = ServiceMod:store_id(),
            DataDir = ServiceMod:data_dir(),
            case hecate_om_store:ensure(StoreId, DataDir) of
                ok           -> ok;
                {error, Why} -> error({hecate_om_store_failed, ServiceMod, Why})
            end
    end.

-spec service_module() -> module() | undefined.
service_module() ->
    persistent_term:get(?SERVICE_MODULE_KEY, undefined).

%% @doc (Re-)publish this service's capabilities onto the mesh.
%% Typically called once at boot; call again when the capability
%% set changes.
-spec advertise_capabilities() -> ok.
advertise_capabilities() ->
    hecate_om_capabilities:publish().

%% @doc Snapshot of this service's health. Used by /health handler.
-spec health() -> hecate_om_service:health().
health() ->
    hecate_om_health:snapshot().

-spec service_cert() -> {ok, binary()} | {error, term()}.
service_cert() ->
    hecate_om_identity:service_cert().

-spec macula_client() -> {ok, term()} | {error, term()}.
macula_client() ->
    hecate_om_identity:macula_client().
