%%% @doc Top-level supervisor for hecate-om.
%%%
%%% Owns four workers and one nested supervisor, all shared by the
%%% hosting service:
%%%   1. hecate_om_identity  — keeps the realm cert + UCAN cached
%%%   2. hecate_om_capabilities — fans capability advertisements out
%%%   3. hecate_om_pubsub_sup — dynamic supervisor of this service's
%%%      macula_subscriber children (piece D)
%%%   4. hecate_om_pubsub_subscriptions — reconciles the desired
%%%      subscription set against (3)'s actual running children
%%%   5. hecate_om_health    — bookkeeping for /health responses
%%%
%%% and, when `health_port' is configured, the Cowboy listener that actually
%%% serves `GET /health' on it (so Podman's HEALTHCHECK and k8s liveness probes
%%% have something to hit).
-module(hecate_om_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 10
    },
    Children = [
        worker(hecate_om_identity),
        worker(hecate_om_capabilities),
        supervisor_child(hecate_om_pubsub_sup),
        worker(hecate_om_pubsub_subscriptions),
        worker(hecate_om_health)
    ] ++ health_listener(),
    {ok, {SupFlags, Children}}.

%% The GET /health HTTP endpoint: a Cowboy listener on `health_port', dispatching
%% to hecate_om_health_handler. The handler and its routes existed but nothing
%% ever mounted them, so /health was dead code and every service reported
%% unhealthy to Podman/k8s. Returns [] (no listener) when no `health_port' is
%% configured, so a service that does not want an HTTP health endpoint simply
%% omits the config.
health_listener() ->
    case application:get_env(hecate_om, health_port) of
        {ok, Port} when is_integer(Port), Port > 0 ->
            Dispatch = cowboy_router:compile([{'_', hecate_om_health_handler:routes()}]),
            [ranch:child_spec(hecate_om_health_http,
                              ranch_tcp, [{port, Port}],
                              cowboy_clear, #{env => #{dispatch => Dispatch}})];
        _ ->
            []
    end.

worker(Module) ->
    #{
        id       => Module,
        start    => {Module, start_link, []},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [Module]
    }.

supervisor_child(Module) ->
    #{
        id       => Module,
        start    => {Module, start_link, []},
        restart  => permanent,
        shutdown => infinity,
        type     => supervisor,
        modules  => [Module]
    }.
