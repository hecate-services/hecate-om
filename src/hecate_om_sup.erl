%%% @doc Top-level supervisor for hecate-om.
%%%
%%% Owns three workers, all shared by the hosting service:
%%%   1. hecate_om_identity  — keeps the realm cert + UCAN cached
%%%   2. hecate_om_capabilities — fans capability advertisements out
%%%   3. hecate_om_health    — bookkeeping for /health responses
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
        worker(hecate_om_health)
    ],
    {ok, {SupFlags, Children}}.

worker(Module) ->
    #{
        id       => Module,
        start    => {Module, start_link, []},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [Module]
    }.
