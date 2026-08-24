%% Live end-to-end proof for piece E (PLAN_HECATE_OM_MESH_WRAPPERS.md):
%% a small (non-chunked) blob round-trips through hecate_om_content's
%% pooled put/get against a real demo-fleet station.
%%
%% Regression-proofs the hard-won lesson this module exists to
%% preserve, not just documents it: the returned MCID is asserted to
%% carry the NON-chunked codec byte (0x55, not 0x56) -- macula_feeder's
%% own is_chunked_mcid/1 pattern -- confirming this content would never
%% get a content_announcement DHT record and so could never have been
%% fetched via macula_download:start_link_direct/4,5 in the first
%% place. A successful round trip through this module IS the proof the
%% pooled path was used, not an assertion about which internal
%% function got called.
%%
%% Runs as part of the default `rebar3 eunit', same tradeoff as the
%% other live station tests in this repo.
-module(hecate_om_content_live_station_tests).
-include_lib("eunit/include/eunit.hrl").

%% A caller-supplied feeder/downloader pair, standing in for a service
%% that needs a custom completion side effect start_feeder/2,3,4 and
%% start_downloader/2,3,4 exist for (the escape-hatch discussion,
%% PLAN_HECATE_OM_MESH_WRAPPERS.md piece E). No `-behaviour(...)'
%% attributes here -- same `init/1' collision as
%% `hecate_om_content.erl' hit, but this is a throwaway test helper,
%% not shipped library code, so the ceremony of splitting into two
%% modules for compiler-checked callback arity isn't worth it here; a
%% wrong arity would just fail the test immediately.
-export([init/1, handle_fed/2, handle_downloaded/2]).

-define(SEED, <<"https://station-de-frankfurt.macula.io:4433">>).

small_blob_round_trips_via_pooled_path_test_() ->
    {timeout, 30, fun run/0}.

run() ->
    {ok, _} = application:ensure_all_started(macula),
    KeyPair = macula_identity:generate(#{puzzle => true}),
    Realm = crypto:strong_rand_bytes(32),
    {ok, Pool} = macula_client:connect([?SEED], #{identity => KeyPair}),
    ok = wait_healthy(Pool, 100),

    ok = meck:new(hecate_om, [passthrough]),
    ok = meck:expect(hecate_om, mesh_handles, fun() -> {ok, Pool, Realm} end),

    Blob = <<"hecate_om_content live round-trip, ", (crypto:strong_rand_bytes(8))/binary>>,
    {ok, Mcid} = hecate_om_content:put(Blob),

    %% The regression-proof: a small blob like this must never carry
    %% the chunked codec byte -- if it did, this test would say
    %% nothing about the pooled-vs-direct lesson.
    ?assertMatch(<<1, 16#55, _/binary>>, Mcid),

    {ok, RoundTripped} = hecate_om_content:get(Mcid),
    ?assertEqual(Blob, RoundTripped),

    %% The escape hatch: a caller-supplied feeder/downloader pair,
    %% proven with a real round trip against the same station, not
    %% just a return-value shape assertion.
    {ok, FeederPid} = hecate_om_content:start_feeder(?MODULE, Blob, self()),
    ?assert(is_pid(FeederPid)),
    CustomMcid = receive
        {custom_feeder_result, {ok, M}} -> M;
        {custom_feeder_result, Other} -> erlang:error({unexpected_feed, Other})
    after 10_000 -> erlang:error(no_feed_result)
    end,

    {ok, DownloaderPid} = hecate_om_content:start_downloader(?MODULE, CustomMcid, self()),
    ?assert(is_pid(DownloaderPid)),
    CustomBytes = receive
        {custom_downloader_result, {ok, B}} -> B;
        {custom_downloader_result, Other2} -> erlang:error({unexpected_download, Other2})
    after 10_000 -> erlang:error(no_download_result)
    end,
    ?assertEqual(Blob, CustomBytes),

    meck:unload(hecate_om),
    catch macula_client:close(Pool),
    ok.

%% Feeder/downloader callbacks for the escape-hatch proof above.
init(Pid) -> {ok, Pid}.

handle_fed(Result, Pid) ->
    Pid ! {custom_feeder_result, Result},
    {stop, normal, Pid}.

handle_downloaded(Result, Pid) ->
    Pid ! {custom_downloader_result, Result},
    {stop, normal, Pid}.

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).
