%%% Live end-to-end proof for piece A (PLAN_HECATE_OM_MESH_WRAPPERS.md):
%%% boots hecate_om as a real OTP application (application:
%%% ensure_all_started/1, not just hecate_om_identity standalone)
%%% against a real demo-fleet station, and confirms the migrated
%%% connection lifecycle (hecate_om_sup's own mesh pool child, via
%%% hecate_om_identity:start_mesh_pool/0) produces a pool genuinely
%%% usable for real mesh work, not just a live pid -- a real piece C
%%% publish succeeds through it.
%%%
%%% test/hecate_om_mesh_pool_SUITE.erl already proves the process-
%%% lifecycle claims (no pool child with no seeds, no boot race, OTP
%%% restarts a crashed pool) against an unreachable seed, which is the
%%% right tool for those -- this file's only job is the one thing that
%%% needs a real station: does the resulting pool actually work.
%%%
%%% Lives in test_live/, NOT test/ -- excluded from the default
%%% `rebar3 eunit' and CI's main gate on purpose; see
%%% hecate_om_capabilities_live_station_tests's moduledoc for why. Run
%%% explicitly:
%%%   rebar3 as live_test eunit --dir test_live
-module(hecate_om_mesh_pool_live_station_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SEED, <<"https://station-de-frankfurt.macula.io:4433">>).
-define(TOPIC, <<"hecate_om_mesh_pool_live_test.topic1">>).

migrated_pool_boots_clean_and_publishes_for_real_test_() ->
    {timeout, 30, fun run/0}.

run() ->
    Realm = crypto:strong_rand_bytes(32),
    application:load(hecate_om),
    application:set_env(hecate_om, health_port, 0),
    application:set_env(hecate_om, station_seeds, [?SEED]),
    application:set_env(hecate_om, realm, Realm),

    {ok, _} = application:ensure_all_started(hecate_om),

    %% No poll/retry here on purpose -- proving the same "no boot race"
    %% claim test/hecate_om_mesh_pool_SUITE.erl proves against an
    %% unreachable seed, this time with a real station on the other
    %% end: application:ensure_all_started/1 returning means the pool
    %% child (and so the whole supervisor tree) already started.
    {ok, Pool} = hecate_om:macula_client(),
    ?assert(is_pid(Pool)),
    ok = wait_healthy(Pool, 100),

    ?assertEqual({ok, Pool, Realm}, hecate_om:mesh_handles()),

    %% The actual point: this pool is not just alive, it is usable --
    %% a real piece C publish through it, against a real station.
    ?assertEqual(ok, hecate_om_pubsub:publish(?TOPIC, #{probe => 1},
                                              #{mode => sync})),

    application:stop(hecate_om),
    application:unload(hecate_om),
    ok.

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).
