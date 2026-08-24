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
%% Lives in test_live/, NOT test/ -- excluded from the default
%% `rebar3 eunit' and CI's main gate on purpose; see
%% hecate_om_capabilities_live_station_tests's moduledoc for why. Run
%% explicitly:
%%   rebar3 as live_test eunit --dir test_live
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
    {ok, FeederPid} = hecate_om_content:start_feeder(?MODULE, Blob, {simple, self()}),
    ?assert(is_pid(FeederPid)),
    CustomMcid = receive
        {custom_feeder_result, {ok, M}} -> M;
        {custom_feeder_result, Other} -> erlang:error({unexpected_feed, Other})
    after 10_000 -> erlang:error(no_feed_result)
    end,

    {ok, DownloaderPid} = hecate_om_content:start_downloader(?MODULE, CustomMcid,
                                                             {simple, self()}),
    ?assert(is_pid(DownloaderPid)),
    CustomBytes = receive
        {custom_downloader_result, {ok, B}} -> B;
        {custom_downloader_result, Other2} -> erlang:error({unexpected_download, Other2})
    after 10_000 -> erlang:error(no_download_result)
    end,
    ?assertEqual(Blob, CustomBytes),

    %% The other motivating scenario for this escape hatch (see the
    %% "imagine such a service exists" discussion,
    %% PLAN_HECATE_OM_MESH_WRAPPERS.md piece E): a batch upload wanting
    %% a per-item completion signal without blocking on each one. Run
    %% to real completion against the live station, not just asserted
    %% possible -- 3 independent feeders started concurrently, this
    %% test acting as its own collector; "all 3 accounted for" is the
    %% batch-complete signal a real service would act on (e.g.
    %% updating a progress row).
    BatchItems = [{I, <<"batch item ", (integer_to_binary(I))/binary>>}
                  || I <- [1, 2, 3]],
    _ = [hecate_om_content:start_feeder(?MODULE, ItemBlob, {batch, I, self()})
         || {I, ItemBlob} <- BatchItems],
    BatchResults = [await_batch_item(I, 10_000) || {I, _} <- BatchItems],
    ?assert(lists:all(fun({ok, M}) -> is_binary(M) end, BatchResults)),
    ?assertEqual(3, length(lists:usort([M || {ok, M} <- BatchResults]))),

    meck:unload(hecate_om),
    catch macula_client:close(Pool),
    ok.

await_batch_item(Index, Timeout) ->
    receive
        {batch_item_done, Index, Result} -> Result
    after Timeout -> erlang:error({no_batch_result, Index})
    end.

%% Feeder/downloader callbacks, dispatching on Args/State shape:
%%   {simple, Pid}              -- one-shot relay
%%   {batch, Index, Collector}  -- batch-upload completion signal
init({simple, _Pid} = Args) -> {ok, Args};
init({batch, _Index, _Collector} = Args) -> {ok, Args}.

handle_fed(Result, {simple, Pid} = State) ->
    Pid ! {custom_feeder_result, Result},
    {stop, normal, State};
handle_fed(Result, {batch, Index, Collector} = State) ->
    Collector ! {batch_item_done, Index, Result},
    {stop, normal, State}.

handle_downloaded(Result, {simple, Pid} = State) ->
    Pid ! {custom_downloader_result, Result},
    {stop, normal, State}.

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).
