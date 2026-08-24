%%% Unit tests for hecate_om_pubsub_subscriptions' pure diff logic and
%%% its no-mesh degrade path.
-module(hecate_om_pubsub_subscriptions_tests).
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% diff/2 — pure, no mesh involved.
%%%===================================================================

diff_starts_missing_and_stops_extra_test() ->
    Desired = [{<<"a">>, mod, args_a}, {<<"b">>, mod, args_b}],
    Current = [<<"b">>, <<"c">>],
    {ToStart, ToStop} = hecate_om_pubsub_subscriptions:diff(Desired, Current),
    ?assertEqual([{<<"a">>, mod, args_a}], ToStart),
    ?assertEqual([<<"c">>], ToStop).

diff_touches_nothing_when_sets_match_test() ->
    Desired = [{<<"a">>, mod, args_a}],
    Current = [<<"a">>],
    ?assertEqual({[], []}, hecate_om_pubsub_subscriptions:diff(Desired, Current)).

diff_on_empty_desired_stops_everything_test() ->
    Current = [<<"a">>, <<"b">>],
    ?assertEqual({[], [<<"a">>, <<"b">>]},
                 hecate_om_pubsub_subscriptions:diff([], Current)).

diff_on_empty_current_starts_everything_test() ->
    Desired = [{<<"a">>, mod, args_a}, {<<"b">>, mod, args_b}],
    ?assertEqual({Desired, []},
                 hecate_om_pubsub_subscriptions:diff(Desired, [])).

%%%===================================================================
%%% Degrades without a mesh — same contract as every other piece.
%%%===================================================================

ensure_degrades_without_mesh_test_() ->
    {setup, fun start_servers/0, fun stop_servers/1,
     fun(_) ->
        [
         %% No pool/realm attached: reconcile no-ops instead of
         %% crashing, and does not start anything.
         ?_assertEqual(ok, hecate_om_pubsub:ensure_subscriptions(
                              [{<<"t">>, some_handler_mod, []}])),
         ?_assertEqual([], supervisor:which_children(hecate_om_pubsub_sup))
        ]
     end}.

start_servers() ->
    {ok, I} = hecate_om_identity:start_link(),
    {ok, Sup} = hecate_om_pubsub_sup:start_link(),
    {ok, Subs} = hecate_om_pubsub_subscriptions:start_link(),
    {I, Sup, Subs}.

stop_servers({I, Sup, Subs}) ->
    catch gen_server:stop(Subs),
    stop_supervisor(Sup),
    catch gen_server:stop(I),
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
