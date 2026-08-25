%%% Unit tests for hecate_om_identity: keypair resolution
%%% (hecate_om_identity:keypair_from/1) -- self-healing generate-on-
%%% missing behavior. Confirmed live: without this, a service whose
%%% job is a direct-dial RPC/Streaming provider (hecate-tube) silently
%%% never advertises anything -- keypair/0 stays {error, no_keypair}
%%% forever, unless something out-of-band provisions the file first.
%%% Also configured_seeds/0 (piece A) and the non-raising accessor
%%% contract (piece H) -- see PLAN_HECATE_OM_MESH_WRAPPERS.md.
-module(hecate_om_identity_tests).
-include_lib("eunit/include/eunit.hrl").

tmp_path() ->
    Name = binary:encode_hex(crypto:strong_rand_bytes(8)),
    filename:join("/tmp", <<"hecate_om_identity_test_", Name/binary, ".key">>).

unconfigured_path_stays_ephemeral_test() ->
    ?assertEqual(undefined, hecate_om_identity:keypair_from(undefined)).

first_boot_generates_and_persists_a_keypair_test() ->
    Path = tmp_path(),
    ?assertEqual(false, filelib:is_regular(Path)),

    KeyPair = hecate_om_identity:keypair_from({ok, Path}),

    ?assertMatch(#{public := _, private := _}, KeyPair),
    #{public := Pub, private := Priv} = KeyPair,
    ?assertEqual(32, byte_size(Pub)),
    ?assertEqual(32, byte_size(Priv)),
    ?assert(filelib:is_regular(Path)),
    %% and it's genuinely loadable back via the same path macula_identity
    %% itself would use -- not just "a file exists".
    ?assertEqual({ok, KeyPair}, macula_identity:load(Path)),
    %% Regression: a non-puzzle-hardened identity's handshake gets
    %% closed with puzzle_invalid by every station in this fleet,
    %% forever -- confirmed live, see generate_and_save/1's own comment.
    ?assert(macula_identity:puzzle_valid(macula_identity:public(KeyPair))),
    file:delete(Path).

existing_keypair_is_loaded_not_regenerated_test() ->
    Path = tmp_path(),
    Original = macula_identity:generate(),
    ok = macula_identity:save(Path, Original),

    Loaded = hecate_om_identity:keypair_from({ok, Path}),

    ?assertEqual(Original, Loaded),
    file:delete(Path).

corrupt_keypair_file_self_heals_test() ->
    Path = tmp_path(),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"not a real key file">>),

    KeyPair = hecate_om_identity:keypair_from({ok, Path}),

    ?assertMatch(#{public := _, private := _}, KeyPair),
    ?assertEqual({ok, KeyPair}, macula_identity:load(Path)),
    ?assert(macula_identity:puzzle_valid(macula_identity:public(KeyPair))),
    file:delete(Path).

%% hecate_om_identity:configured_seeds/0 -- exported for hecate_om_sup's
%% own use deciding whether the mesh pool child (piece A,
%% PLAN_HECATE_OM_MESH_WRAPPERS.md) belongs in the children list at
%% all, which makes a wrong answer here higher-stakes than before this
%% piece: it used to only pick which seeds a connect attempt used, now
%% it decides whether a pool is started at all.
configured_seeds_test_() ->
    {setup, fun clear_seed_config/0, fun restore_seed_config/1,
     fun(_) ->
         [
          ?_assertEqual([], with_seed_config(false, undefined, fun hecate_om_identity:configured_seeds/0)),
          ?_assertEqual([<<"https://a:1">>, <<"https://b:2">>],
                        with_seed_config(false, [<<"https://a:1">>, <<"https://b:2">>],
                                          fun hecate_om_identity:configured_seeds/0)),
          ?_assertEqual([<<"https://env:9">>],
                        with_seed_config("https://env:9", [<<"https://appenv:1">>],
                                          fun hecate_om_identity:configured_seeds/0)),
          ?_assertEqual([<<"https://a:1">>, <<"https://b:2">>],
                        with_seed_config(" https://a:1 , https://b:2 ,, ", undefined,
                                          fun hecate_om_identity:configured_seeds/0))
         ]
     end}.

clear_seed_config() ->
    {os:getenv("MACULA_STATION_SEEDS"), application:get_env(hecate_om, station_seeds)}.

restore_seed_config({Env, AppEnv}) ->
    restore_env(Env),
    restore_app_env(AppEnv).

restore_env(false) -> os:unsetenv("MACULA_STATION_SEEDS");
restore_env(Val)   -> os:putenv("MACULA_STATION_SEEDS", Val).

restore_app_env(undefined)  -> application:unset_env(hecate_om, station_seeds);
restore_app_env({ok, Seeds}) -> application:set_env(hecate_om, station_seeds, Seeds).

%% EnvVal: string to putenv, or `false' to unsetenv. AppEnvSeeds:
%% seed list to set as app env, or `undefined' to unset.
with_seed_config(EnvVal, AppEnvSeeds, Fun) ->
    set_env(EnvVal),
    set_app_env(AppEnvSeeds),
    Fun().

set_env(false)  -> os:unsetenv("MACULA_STATION_SEEDS");
set_env(EnvVal) -> os:putenv("MACULA_STATION_SEEDS", EnvVal).

set_app_env(undefined) -> application:unset_env(hecate_om, station_seeds);
set_app_env(Seeds)     -> application:set_env(hecate_om, station_seeds, Seeds).

%% Piece H (PLAN_HECATE_OM_MESH_WRAPPERS.md): calling an accessor
%% before hecate_om_identity has started must degrade to {error,
%% not_booted} rather than raising {noproc, _}. Several OTHER test
%% modules in this suite start a real hecate_om_identity in their own
%% fixtures, so "not started yet" cannot be assumed from ordinary
%% EUnit execution order in a shared VM -- ensured directly here
%% instead, same defensive-teardown discipline as
%% hecate_om_pubsub_subscriptions_tests.erl's stop_supervisor/1.
accessors_degrade_instead_of_raising_when_not_booted_test_() ->
    {setup, fun ensure_identity_not_running/0, fun restore_identity/1,
     fun(_) ->
        [
         ?_assertEqual({error, not_booted}, hecate_om_identity:realm()),
         ?_assertEqual({error, not_booted}, hecate_om_identity:keypair()),
         ?_assertEqual({error, not_booted}, hecate_om_identity:service_cert()),
         ?_assertEqual({error, not_booted}, hecate_om_identity:cert_chain()),
         ?_assertEqual({error, not_booted}, hecate_om_identity:realm_ca()),
         %% org/0's contract is "always a binary" -- not_booted collapses
         %% into the same placeholder as "unconfigured", not a new shape.
         ?_assertEqual(<<"_">>, hecate_om_identity:org())
        ]
     end}.

%% Returns whatever was running before (a pid, or `undefined') so the
%% teardown can decide whether to put a fresh one back -- this suite
%% doesn't own whether some other module wants one alive afterwards,
%% only that it's genuinely absent for the body of this test.
ensure_identity_not_running() ->
    case whereis(hecate_om_identity) of
        undefined -> undefined;
        Pid ->
            unlink(Pid),
            Ref = monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 2_000 -> ok
            end,
            running
    end.

restore_identity(undefined) -> ok;
restore_identity(running)   -> {ok, _} = hecate_om_identity:start_link(), ok.
