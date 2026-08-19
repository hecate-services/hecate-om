%%% Unit tests for the pure record-building + resolution helpers of
%%% hecate_om_capabilities (direct-dial discovery, Slice 2). The mesh
%%% I/O (put_record / find_records / links) is thin glue over macula,
%%% covered by macula-station's DHT handler tests and macula's record
%%% tests; here we prove hecate-om builds the right record, derives the
%%% same key on both sides, and decodes/verifies what it reads back.
-module(hecate_om_capabilities_tests).
-include_lib("eunit/include/eunit.hrl").

realm()      -> crypto:strong_rand_bytes(32).
station()    -> crypto:strong_rand_bytes(32).
cap(Name)    -> #{name => Name, version => 1}.

%% Provider (advertising, from a capability map) and consumer (looking
%% up, from a bare name) must derive the SAME URI so their storage keys
%% match — otherwise a consumer could never find the provider.
procedure_uri_agrees_and_is_realm_scoped_test() ->
    R    = realm(),
    Name = <<"hecate-rag.query">>,
    FromCap  = hecate_om_capabilities:procedure_uri(R, cap(Name)),
    FromName = hecate_om_capabilities:procedure_uri(R, Name),
    ?assertEqual(FromName, FromCap),
    ?assertEqual(<<(binary:encode_hex(R))/binary, "/", Name/binary>>, FromCap).

build_advertisement_round_trips_test() ->
    Kp = macula_identity:generate(),
    R  = realm(),
    St = station(),
    Rec = hecate_om_capabilities:build_advertisement(Kp, R, cap(<<"svc.do">>), St),
    #{advertiser_node := Adv,
      serving_station := Sta,
      procedure_uri   := Uri} = macula_record:read_procedure_advertisement(Rec),
    ?assertEqual(macula_identity:public(Kp), Adv),
    ?assertEqual(St, Sta),
    ?assertEqual(hecate_om_capabilities:procedure_uri(R, <<"svc.do">>), Uri),
    %% and the record verifies (it was signed by the advertiser)
    ?assertMatch({ok, _}, macula_record:verify(Rec)).

%% The Slice-2 DONE-WHEN in pure form: two providers advertise one
%% capability; decode_resolved recovers both as {advertiser, station}.
decode_resolved_returns_verified_providers_test() ->
    R   = realm(),
    St1 = station(),
    St2 = station(),
    KpA = macula_identity:generate(),
    KpB = macula_identity:generate(),
    A = hecate_om_capabilities:build_advertisement(KpA, R, cap(<<"c">>), St1),
    B = hecate_om_capabilities:build_advertisement(KpB, R, cap(<<"c">>), St2),
    Got = hecate_om_capabilities:decode_resolved([A, B]),
    ?assertEqual(2, length(Got)),
    ?assert(lists:member(#{advertiser => macula_identity:public(KpA),
                           serving_station => St1}, Got)),
    ?assert(lists:member(#{advertiser => macula_identity:public(KpB),
                           serving_station => St2}, Got)).

decode_resolved_drops_tampered_and_foreign_records_test() ->
    R   = realm(),
    St  = station(),
    Kp  = macula_identity:generate(),
    Good     = hecate_om_capabilities:build_advertisement(Kp, R, cap(<<"c">>), St),
    Tampered = Good#{signature := <<0:512>>},
    %% a node_record is not a procedure_advertisement
    NodeKp = macula_identity:generate(),
    Node   = macula_record:sign(
               macula_record:node_record(macula_identity:public(NodeKp), [], 0),
               NodeKp),
    Got = hecate_om_capabilities:decode_resolved([Tampered, Node, Good]),
    ?assertEqual([#{advertiser => macula_identity:public(Kp),
                    serving_station => St}], Got).

%%% gen_server + graceful degradation (no mesh) — this is the path that
%%% actually runs at boot before a pool/keypair are present. Exercises
%%% init, register/publish/lookup/list, and the no-op / empty degradation.

gen_server_degrades_without_mesh_test_() ->
    {setup, fun start_servers/0, fun stop_servers/1,
     fun(_) ->
        Cap = #{name => <<"svc.do">>, version => 1},
        [
         %% register + publish must not crash when there is no pool /
         %% keypair / realm — they no-op and the timer retries later.
         ?_assertEqual(ok, hecate_om_capabilities:register([Cap])),
         ?_assertEqual(ok, hecate_om_capabilities:publish()),
         %% own caps are still reported (used by /health + the SUITE)
         ?_assertEqual([Cap], hecate_om_capabilities:list()),
         %% resolution with no pool yields an empty set, not a crash
         ?_assertEqual({ok, []}, hecate_om_capabilities:lookup(<<"svc.do">>)),
         %% and identity reports the missing signing key cleanly
         ?_assertEqual({error, no_keypair}, hecate_om_identity:keypair())
        ]
     end}.

start_servers() ->
    {ok, I} = hecate_om_identity:start_link(),
    {ok, C} = hecate_om_capabilities:start_link(),
    {I, C}.

stop_servers({I, C}) ->
    catch gen_server:stop(C),
    catch gen_server:stop(I),
    ok.
