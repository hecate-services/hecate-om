%%% @doc Smoke tests for hecate_om.
-module(hecate_om_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([behaviour_attributes/1, boot_dummy_service/1, health_snapshot/1]).

all() ->
    [behaviour_attributes, boot_dummy_service, health_snapshot].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hecate_om),
    Config.

end_per_suite(_Config) ->
    application:stop(hecate_om),
    ok.

behaviour_attributes(_Config) ->
    %% hecate_om_service must declare exactly 6 callbacks.
    Callbacks = hecate_om_service:behaviour_info(callbacks),
    ?assertEqual(6, length(Callbacks)),
    Names = lists:map(fun({N, _A}) -> N end, Callbacks),
    Expected = lists:sort([info, start, stop, health, capabilities, identity_spec]),
    ?assertEqual(Expected, lists:sort(Names)).

boot_dummy_service(_Config) ->
    {ok, _Pid} = hecate_om:boot(dummy_service, #{}),
    ?assertEqual(dummy_service, hecate_om:service_module()),
    Caps = hecate_om_capabilities:list(),
    ?assertEqual([#{name => <<"dummy.do_thing">>, version => 1}], Caps).

health_snapshot(_Config) ->
    ?assertEqual(ok, hecate_om:health()).
