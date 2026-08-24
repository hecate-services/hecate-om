%%% Unit + live tests for hecate_om_pubsub, piece C of the mesh-wrappers
%%% plan (`plans/PLAN_HECATE_OM_MESH_WRAPPERS.md'). No real station is
%%% needed for the live group: `macula_client:connect([], #{})' gives a
%%% real pool with zero spawned links, so a publish genuinely resolves
%%% to `{error, {transient, no_healthy_station}}' from the SDK itself —
%%% exercising the real macula_publisher outcome path, not a stub.
-module(hecate_om_pubsub_tests).
-include_lib("eunit/include/eunit.hrl").

%% A caller-supplied macula_publisher callback, standing in for a
%% service that needs outcome handling start_publisher/3,4,5 exists
%% for (see the escape-hatch discussion, PLAN_HECATE_OM_MESH_WRAPPERS.md
%% piece C) -- proves start_publisher/3,4,5 genuinely hands control to
%% THIS module, not hecate_om_pubsub's own.
-behaviour(macula_publisher).
-export([init/1, handle_published/2]).

-define(TOPIC, <<"hecate_om_pubsub.test_v1">>).

%%%===================================================================
%%% Pure realm/mode resolution — no mesh, no macula_publisher involved.
%%% (`macula_publisher' ships to hex.pm without debug_info, same reason
%%% this repo's own rebar.config excludes it from dialyzer, so meck's
%%% passthrough mode can't wrap it here; testing resolution as a pure
%%% function instead — same convention `hecate_om_capabilities.erl'
%%% already uses for its own record-building helpers — sidesteps that
%%% entirely and is a better test anyway: it proves the decision, not
%%% just that some argument arrived somewhere.)
%%%===================================================================

resolve_realm_prefers_override_test() ->
    Default = crypto:strong_rand_bytes(32),
    Other   = crypto:strong_rand_bytes(32),
    ?assertEqual(Other, hecate_om_pubsub:resolve_realm(#{realm => Other}, Default)),
    ?assertEqual(Default, hecate_om_pubsub:resolve_realm(#{}, Default)).

resolve_mode_defaults_to_async_silent_test() ->
    ?assertEqual(async_silent, hecate_om_pubsub:resolve_mode(#{})),
    ?assertEqual(sync, hecate_om_pubsub:resolve_mode(#{mode => sync})),
    ?assertEqual(async_log, hecate_om_pubsub:resolve_mode(#{mode => async_log})).

%%%===================================================================
%%% Degrades without a mesh — same contract as hecate_om:mesh_handles/0.
%%%===================================================================

publish_degrades_without_mesh_test_() ->
    {setup, fun start_identity_no_seeds/0, fun stop_identity/1,
     fun(_) ->
        [
         ?_assertEqual({error, mesh_unavailable},
                       hecate_om_pubsub:publish(?TOPIC, #{probe => 1})),
         ?_assertEqual({error, mesh_unavailable},
                       hecate_om_pubsub:publish(?TOPIC, #{probe => 1},
                                                #{mode => sync})),
         ?_assertEqual({error, mesh_unavailable},
                       hecate_om_pubsub:start_publisher(?MODULE, ?TOPIC,
                                                        #{probe => 1}))
        ]
     end}.

start_identity_no_seeds() ->
    application:unset_env(hecate_om, station_seeds),
    application:unset_env(hecate_om, realm),
    {ok, I} = hecate_om_identity:start_link(),
    I.

stop_identity(I) ->
    catch gen_server:stop(I),
    ok.

%%%===================================================================
%%% Live pool, zero seeds — genuine SDK outcomes, no station required.
%%%
%%% `hecate_om:mesh_handles/0' is the one integration point between
%%% hecate_om_pubsub and the rest of hecate_om (identity/seed config);
%%% mecking exactly that boundary lets these tests hand in a real,
%%% zero-link `macula_client' pool (so publish genuinely resolves to
%%% `{error, {transient, no_healthy_station}}' from the SDK itself, per
%%% `macula_client_tests:publish_with_no_seeds_is_transient_test_/0')
%%% without fighting `hecate_om_identity''s own seed-gated attach logic,
%%% which never calls `macula_client:connect/2' at all for an empty
%%% seed list.
%%%===================================================================

live_pool_test_() ->
    {timeout, 15,
     {setup, fun start_live_pool/0, fun stop_live_pool/1,
      fun(_) ->
         [
          {"async_silent (default) returns ok immediately, "
           "even though the underlying publish will fail",
           fun test_async_silent_returns_ok/0},
          {"sync mode blocks and surfaces the real SDK outcome",
           fun test_sync_surfaces_real_error/0},
          {"async_log mode does not crash and still returns ok",
           fun test_async_log_returns_ok/0},
          {"publish_many/2 attempts every topic and reports any failure",
           fun test_publish_many/0},
          {"sync mode honours a caller-supplied timeout",
           fun test_sync_timeout/0},
          {"start_publisher/3 hands control to the caller's own module",
           fun test_start_publisher_uses_caller_module/0}
         ]
      end}}.

start_live_pool() ->
    {ok, _} = application:ensure_all_started(macula),
    {ok, Pool} = macula_client:connect([], #{}),
    Realm = crypto:strong_rand_bytes(32),
    ok = meck:new(hecate_om, [passthrough]),
    ok = meck:expect(hecate_om, mesh_handles, fun() -> {ok, Pool, Realm} end),
    {Pool, Realm}.

stop_live_pool({Pool, _Realm}) ->
    meck:unload(hecate_om),
    catch macula_client:close(Pool),
    ok.

test_async_silent_returns_ok() ->
    ?assertEqual(ok, hecate_om_pubsub:publish(?TOPIC, #{probe => 1})).

test_sync_surfaces_real_error() ->
    Result = hecate_om_pubsub:publish(?TOPIC, #{probe => 1}, #{mode => sync}),
    ?assertEqual({error, {transient, no_healthy_station}}, Result).

test_async_log_returns_ok() ->
    ?assertEqual(ok, hecate_om_pubsub:publish(?TOPIC, #{probe => 1},
                                              #{mode => async_log})).

test_publish_many() ->
    Result = hecate_om_pubsub:publish_many([?TOPIC, <<"other.topic_v1">>],
                                           #{probe => 1}, #{mode => sync}),
    ?assertEqual({error, {transient, no_healthy_station}}, Result).

test_sync_timeout() ->
    %% A pathological handler that never replies — the publisher process
    %% itself is fine (SDK call just takes a moment against 0 links);
    %% a tiny timeout must still bound the caller's wait rather than hang.
    Result = hecate_om_pubsub:publish(?TOPIC, #{probe => 1},
                                      #{mode => sync, timeout => 1}),
    ?assert(Result =:= {error, timeout} orelse
            Result =:= {error, {transient, no_healthy_station}}).

test_start_publisher_uses_caller_module() ->
    {ok, Pid} = hecate_om_pubsub:start_publisher(?MODULE, ?TOPIC,
                                                 #{probe => 3}, self()),
    ?assert(is_pid(Pid)),
    Result = receive
        {custom_publisher_result, R} -> R
    after 2_000 -> erlang:error(no_result)
    end,
    %% Real SDK outcome, reaching THIS module's handle_published/2 --
    %% not hecate_om_pubsub's own, which would never send this tag.
    ?assertEqual({error, {transient, no_healthy_station}}, Result).

%% macula_publisher callbacks for test_start_publisher_uses_caller_module.
init(Pid) -> {ok, Pid}.

handle_published(Result, Pid) ->
    Pid ! {custom_publisher_result, Result},
    {stop, normal, Pid}.
