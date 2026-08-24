%% Live end-to-end proof for piece D (PLAN_HECATE_OM_MESH_WRAPPERS.md):
%% a service declaring a subscription via `hecate_om_pubsub:ensure_
%% subscriptions/1' genuinely receives real events published (via
%% piece C's `hecate_om_pubsub:publish/2') on a real demo-fleet
%% station -- and `ensure_subscriptions/1' called again with a changed
%% desired set starts exactly the new child and stops exactly the
%% removed one, touching nothing else (the supervision-membership
%% design for a `federation_inbox'-shaped dynamic topic set).
%%
%% Lives in test_live/, NOT test/ -- excluded from the default
%% `rebar3 eunit' and CI's main gate on purpose; see
%% `hecate_om_capabilities_live_station_tests.erl''s moduledoc for why.
%% Run explicitly:
%%   rebar3 as live_test eunit --dir test_live
-module(hecate_om_pubsub_subscriptions_live_tests).
-include_lib("eunit/include/eunit.hrl").

-behaviour(macula_subscriber).
-export([init/1, handle_event/4]).

-define(SEED, <<"https://station-de-frankfurt.macula.io:4433">>).
-define(TOPIC1, <<"hecate_om_subs_test.topic1">>).
-define(TOPIC2, <<"hecate_om_subs_test.topic2">>).

subscriptions_receive_real_events_and_are_dynamic_test_() ->
    {timeout, 30, fun run/0}.

run() ->
    {ok, _} = application:ensure_all_started(macula),
    KeyPair = macula_identity:generate(#{puzzle => true}),
    Realm = crypto:strong_rand_bytes(32),
    {ok, Pool} = macula_client:connect([?SEED], #{identity => KeyPair}),
    ok = wait_healthy(Pool, 100),

    ok = meck:new(hecate_om, [passthrough]),
    ok = meck:expect(hecate_om, mesh_handles, fun() -> {ok, Pool, Realm} end),

    {ok, Sup} = hecate_om_pubsub_sup:start_link(),
    {ok, Subs} = hecate_om_pubsub_subscriptions:start_link(),

    %% 1. Declare one subscription, receive a real event on it.
    ok = hecate_om_pubsub:ensure_subscriptions([{?TOPIC1, ?MODULE, self()}]),
    ok = hecate_om_pubsub:publish(?TOPIC1, #{probe => 1}, #{mode => sync}),
    Event1 = await_event(?TOPIC1, 10_000),
    ?assertMatch(#{probe := 1}, Event1),

    [{?TOPIC1, Topic1Pid, worker, _}] = supervisor:which_children(hecate_om_pubsub_sup),
    ?assert(is_pid(Topic1Pid)),

    %% 2. Add a second topic. The first child is untouched (same pid);
    %% the new one is genuinely subscribed too.
    ok = hecate_om_pubsub:ensure_subscriptions(
           [{?TOPIC1, ?MODULE, self()}, {?TOPIC2, ?MODULE, self()}]),
    ok = hecate_om_pubsub:publish(?TOPIC2, #{probe => 2}, #{mode => sync}),
    Event2 = await_event(?TOPIC2, 10_000),
    ?assertMatch(#{probe := 2}, Event2),

    Children2 = lists:sort(supervisor:which_children(hecate_om_pubsub_sup)),
    [{?TOPIC1, Topic1PidAgain, worker, _}, {?TOPIC2, Topic2Pid, worker, _}] = Children2,
    ?assertEqual(Topic1Pid, Topic1PidAgain),
    ?assert(is_pid(Topic2Pid)),

    %% 3. Remove the first topic. Only it disappears; the second one's
    %% pid is still untouched.
    ok = hecate_om_pubsub:ensure_subscriptions([{?TOPIC2, ?MODULE, self()}]),
    Children3 = supervisor:which_children(hecate_om_pubsub_sup),
    ?assertEqual([{?TOPIC2, Topic2Pid, worker, [?MODULE]}], Children3),

    %% Stop the subscribers before closing the pool -- otherwise
    %% macula_subscriber correctly (if noisily) reacts to a real
    %% pool_closed event and crashes, which is expected behavior but
    %% not what this test is trying to demonstrate.
    stop_supervisor(Sup),
    catch gen_server:stop(Subs),
    meck:unload(hecate_om),
    catch macula_client:close(Pool),
    ok.

%% supervisor:stop/1 does not exist (unlike gen_server:stop/1) --
%% unlink first so the shutdown exit signal doesn't propagate back and
%% kill this (non-trapping) test process, then wait for confirmation.
stop_supervisor(Sup) ->
    unlink(Sup),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5_000 -> ok
    end.

await_event(Topic, Timeout) ->
    receive
        {subscriber_event, Topic, Payload} -> Payload
    after Timeout ->
        erlang:error({event_not_received, Topic})
    end.

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).

%% macula_subscriber callbacks -- forward every event to whichever
%% test process subscribed (passed as Args).
init(TestPid) -> {ok, TestPid}.

handle_event(Topic, Payload, _Meta, TestPid) ->
    TestPid ! {subscriber_event, Topic, Payload},
    {noreply, TestPid}.
