%%% Unit tests for the pure record-building + resolution helpers of
%%% hecate_om_capabilities (direct-dial discovery, Slice 2). The mesh
%%% I/O (put_record / find_records / links) is thin glue over macula,
%%% covered by macula-station's DHT handler tests and macula's record
%%% tests; here we prove hecate-om builds the right record, derives the
%%% same key on both sides, and decodes/verifies what it reads back.
-module(hecate_om_capabilities_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

%% Placeholder macula_response callback module (piece B tests below) —
%% referenced only by module atom (`{?MODULE, []}'), dispatched at real
%% inbound-call time, which these tests never reach (no live station).
-behaviour(macula_response).
-export([init/1, handle_request/2]).

realm()      -> crypto:strong_rand_bytes(32).
station()    -> crypto:strong_rand_bytes(32).
cap(Name)    -> #{name => Name, version => 1}.

%% Provider (advertising, from a capability map) and consumer (looking
%% up, from a bare name) must derive the SAME URI so their storage keys
%% match — otherwise a consumer could never find the provider.
procedure_uri_agrees_and_is_realm_scoped_test() ->
    R    = realm(),
    Name = <<"hecate-rag.query">>,
    FromCap  = hecate_om_capabilities:procedure_uri(R, <<"acme">>, cap(Name)),
    FromName = hecate_om_capabilities:procedure_uri(R, <<"acme">>, Name),
    ?assertEqual(FromName, FromCap),
    ?assertEqual(<<(binary:encode_hex(R))/binary, "/acme/", Name/binary>>, FromCap).

build_advertisement_round_trips_test() ->
    Kp = macula_identity:generate(),
    R  = realm(),
    St = station(),
    Rec = hecate_om_capabilities:build_advertisement(Kp, R, <<"acme">>, cap(<<"svc.do">>), St),
    #{advertiser_node := Adv,
      serving_station := Sta,
      procedure_uri   := Uri} = macula_record:read_procedure_advertisement(Rec),
    ?assertEqual(macula_identity:public(Kp), Adv),
    ?assertEqual(St, Sta),
    ?assertEqual(hecate_om_capabilities:procedure_uri(R, <<"acme">>, <<"svc.do">>), Uri),
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
    A = hecate_om_capabilities:build_advertisement(KpA, R, <<"acme">>, cap(<<"c">>), St1),
    B = hecate_om_capabilities:build_advertisement(KpB, R, <<"acme">>, cap(<<"c">>), St2),
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
    Good     = hecate_om_capabilities:build_advertisement(Kp, R, <<"acme">>, cap(<<"c">>), St),
    Tampered = Good#{signature := <<0:512>>},
    %% a node_record is not a procedure_advertisement
    NodeKp = macula_identity:generate(),
    Node   = macula_record:sign(
               macula_record:node_record(macula_identity:public(NodeKp), [], 0),
               NodeKp),
    Got = hecate_om_capabilities:decode_resolved([Tampered, Node, Good]),
    ?assertEqual([#{advertiser => macula_identity:public(Kp),
                    serving_station => St}], Got).

station_url_brackets_ipv6_only_test() ->
    ?assertEqual(<<"quic://[::1]:4433">>,
                 hecate_om_capabilities:station_url(<<"::1">>, 4433)),
    ?assertEqual(<<"quic://[2001:db8::5]:9000">>,
                 hecate_om_capabilities:station_url(<<"2001:db8::5">>, 9000)),
    ?assertEqual(<<"quic://10.0.0.7:4433">>,
                 hecate_om_capabilities:station_url(<<"10.0.0.7">>, 4433)).

%%% Direct-dial dual-trust (Slice 7c Direction B) — the advertise side
%%% embeds the service cert chain; the SDK verifies it to the realm CA.

%% build_advertisement/6 embeds the cert chain so a verifying consumer
%% can read it back off the record; /5 leaves it absent (open-mode).
build_advertisement_embeds_cert_chain_test() ->
    Kp    = macula_identity:generate(),
    R     = realm(),
    St    = station(),
    Chain = <<"-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n">>,
    With  = hecate_om_capabilities:build_advertisement(
              Kp, R, <<"acme">>, cap(<<"svc.do">>), St, #{cert_chain => Chain}),
    Without = hecate_om_capabilities:build_advertisement(
                Kp, R, <<"acme">>, cap(<<"svc.do">>), St),
    ?assertMatch(#{cert_chain := Chain},
                 macula_record:read_procedure_advertisement(With)),
    ?assertMatch(#{cert_chain := undefined},
                 macula_record:read_procedure_advertisement(Without)).

%% An advertisement built with a REAL service-cert chain verifies to the
%% realm CA via the SDK; the same capability advertised without a chain
%% (a would-be squatter in verify-mode) is rejected as no_cert_chain.
%% This proves the embed side produces records the verify side accepts.
build_advertisement_chain_verifies_to_realm_ca_test() ->
    Kp     = macula_identity:generate(),
    AdvKey = macula_identity:public(Kp),
    R      = realm(),
    St     = station(),
    #{realm_ca := RealmCa, chain := Chain} = issue_chain(AdvKey, <<"acme">>),
    Good = hecate_om_capabilities:build_advertisement(
             Kp, R, <<"acme">>, cap(<<"svc.do">>), St, #{cert_chain => Chain}),
    NoChain = hecate_om_capabilities:build_advertisement(
                Kp, R, <<"acme">>, cap(<<"svc.do">>), St),
    ?assertEqual(ok,
                 macula_record:verify_advertisement_cert_chain(RealmCa, Good, <<"acme">>)),
    ?assertEqual({error, no_cert_chain},
                 macula_record:verify_advertisement_cert_chain(RealmCa, NoChain, <<"acme">>)).

%%% Piece B (PLAN_HECATE_OM_MESH_WRAPPERS.md): a capability carrying
%%% `handler => {Module, Args}' is advertised via
%%% `macula_response:advertise_direct/7' instead of the legacy bare
%%% `put_record'. `has_handler/1' is the dispatch decision;
%%% `reuse_sup_opts/1' is what keeps a periodic re-advertise from
%%% leaking one factory supervisor per tick.

has_handler_distinguishes_capability_shapes_test() ->
    ?assert(hecate_om_capabilities:has_handler(
              #{name => <<"svc.do">>, version => 1,
                handler => {my_mod, []}})),
    ?assertNot(hecate_om_capabilities:has_handler(
                 #{name => <<"svc.do">>, version => 1})).

reuse_sup_opts_carries_a_known_sup_and_nothing_else_test() ->
    ?assertEqual(#{}, hecate_om_capabilities:reuse_sup_opts(undefined)),
    Sup = self(),
    ?assertEqual(#{reuse_sup => Sup},
                 hecate_om_capabilities:reuse_sup_opts(Sup)).

%%% gen_server + graceful degradation (no mesh) — this is the path that
%%% actually runs at boot before a pool/keypair are present. Exercises
%%% init, register/publish/lookup/list, and the no-op / empty degradation.

gen_server_degrades_without_mesh_test_() ->
    {setup, fun start_servers/0, fun stop_servers/1,
     fun(_) ->
        Cap = #{name => <<"svc.do">>, version => 1},
        %% A handler-bearing capability must degrade exactly the same
        %% way — advertise_direct is never even reached with no
        %% pool/keypair/realm, same as the legacy put_record path.
        HandlerCap = #{name => <<"svc.answer">>, version => 1,
                       handler => {?MODULE, []}},
        [
         %% register + publish must not crash when there is no pool /
         %% keypair / realm — they no-op and the timer retries later.
         ?_assertEqual(ok, hecate_om_capabilities:register([Cap, HandlerCap])),
         ?_assertEqual(ok, hecate_om_capabilities:publish()),
         %% own caps are still reported (used by /health + the SUITE)
         ?_assertEqual([Cap, HandlerCap], hecate_om_capabilities:list()),
         %% resolution with no pool yields an empty set, not a crash
         ?_assertEqual({ok, []}, hecate_om_capabilities:lookup(<<"svc.do">>)),
         %% and identity reports the missing signing key cleanly
         ?_assertEqual({error, no_keypair}, hecate_om_identity:keypair()),
         %% call_capability with no pool degrades, does not crash
         ?_assertEqual({error, not_configured},
                       hecate_om_capabilities:call_capability(<<"acme">>,
                                                              <<"svc.do">>,
                                                              #{}, 1_000, #{}))
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

%%%===================================================================
%%% Live pool, zero seeds — reaches the real macula_response:advertise_direct
%%% boundary without a station. Same technique as hecate_om_pubsub_tests:
%%% macula_client:connect([], #{}) gives a real pool with zero spawned
%%% links, so macula:advertise/5 (which advertise_direct calls first)
%%% genuinely returns {error, no_healthy_station} from the SDK itself —
%%% proving the wiring reaches macula_response correctly, even though it
%%% can't succeed without a real station to register with. The stronger
%%% claim -- a handler-bearing capability is genuinely CALLABLE end to
%%% end -- needs a real macula-station and is NOT covered here; see the
%%% plan doc's acceptance note for piece B.
%%%===================================================================

live_pool_handler_capability_test_() ->
    {timeout, 15,
     {setup, fun start_live/0, fun stop_live/1,
      fun(_) ->
         Cap = #{name => <<"svc.answer">>, version => 1,
                handler => {?MODULE, []}},
         [
          {"register with a handler-bearing capability reaches the SDK "
           "boundary and degrades cleanly with no healthy station",
           fun() ->
              ?assertEqual(ok, hecate_om_capabilities:register([Cap]))
           end},
          {"a second tick (simulating the 30s republish timer) is just "
           "as stable -- proves repeated failed advertise_direct calls "
           "don't accumulate state or crash the worker",
           fun() ->
              ?assertEqual(ok, hecate_om_capabilities:publish()),
              ?assertEqual(ok, hecate_om_capabilities:publish())
           end}
         ]
      end}}.

init(_Args) -> {ok, []}.
handle_request(_Payload, State) -> {reply, ok, State}.

start_live() ->
    {ok, _} = application:ensure_all_started(macula),
    {ok, Pool} = macula_client:connect([], #{}),
    Realm = crypto:strong_rand_bytes(32),
    KeyPair = macula_identity:generate(),
    %% A real hecate_om_identity too -- do_advertise/2 also calls org/0
    %% and cert_chain/0, which passthrough would otherwise route to a
    %% real gen_server:call with nothing registered to answer it.
    {ok, I} = hecate_om_identity:start_link(),
    ok = meck:new(hecate_om_identity, [passthrough]),
    ok = meck:expect(hecate_om_identity, macula_client, fun() -> {ok, Pool} end),
    ok = meck:expect(hecate_om_identity, realm, fun() -> {ok, Realm} end),
    ok = meck:expect(hecate_om_identity, keypair, fun() -> {ok, KeyPair} end),
    {ok, C} = hecate_om_capabilities:start_link(),
    {I, Pool, C}.

stop_live({I, Pool, C}) ->
    catch gen_server:stop(C),
    meck:unload(hecate_om_identity),
    catch gen_server:stop(I),
    catch macula_client:close(Pool),
    ok.

%%% Minimal in-process X.509 CA (realm CA -> org CA -> Ed25519 leaf
%%% binding `LeafPub', O=`Org'). Returns the trusted realm CA PEM and the
%%% leaf-first [leaf, org CA] PEM bundle a service embeds.
issue_chain(LeafPub, Org) ->
    {RealmPub, RealmPriv} = ca_key(),
    {OrgPub, OrgPriv}     = ca_key(),
    RealmSubj = subject(<<"io.macula">>, <<"io.macula">>),
    OrgSubj   = subject(<<"io.macula.", Org/binary>>, Org),
    LeafSubj  = subject(<<"mri:app:io.macula/", Org/binary, "/svc">>, Org),
    RealmDer = sign_cert(RealmSubj, ed_spki(RealmPub), RealmSubj, RealmPriv, true),
    OrgDer   = sign_cert(OrgSubj, ed_spki(OrgPub), RealmSubj, RealmPriv, true),
    LeafDer  = sign_cert(LeafSubj, ed_spki(LeafPub), OrgSubj, OrgPriv, false),
    #{realm_ca => pem([RealmDer]), chain => pem([LeafDer, OrgDer])}.

ca_key() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    {Pub, #'ECPrivateKey'{version = 1, privateKey = Priv,
                          parameters = {namedCurve, ?'id-Ed25519'},
                          publicKey = Pub}}.

ed_spki(Pub) ->
    #'OTPSubjectPublicKeyInfo'{
       algorithm = #'PublicKeyAlgorithm'{algorithm = ?'id-Ed25519',
                                         parameters = asn1_NOVALUE},
       subjectPublicKey = #'ECPoint'{point = Pub}}.

subject(CN, O) ->
    {rdnSequence,
     [[#'AttributeTypeAndValue'{type = {2, 5, 4, 3}, value = {utf8String, CN}}],
      [#'AttributeTypeAndValue'{type = {2, 5, 4, 10}, value = {utf8String, O}}]]}.

sign_cert(Subject, Spki, IssuerSubject, IssuerKey, IsCA) ->
    TBS = #'OTPTBSCertificate'{
             version = v3,
             serialNumber = rand:uniform(1 bsl 60),
             signature = #'SignatureAlgorithm'{algorithm = ?'id-Ed25519',
                                               parameters = asn1_NOVALUE},
             issuer = IssuerSubject,
             validity = #'Validity'{notBefore = {utcTime, "230101000000Z"},
                                    notAfter  = {utcTime, "330101000000Z"}},
             subject = Subject,
             subjectPublicKeyInfo = Spki,
             extensions = [basic_constraints(IsCA)]},
    public_key:pkix_sign(TBS, IssuerKey).

basic_constraints(IsCA) ->
    #'Extension'{extnID = ?'id-ce-basicConstraints', critical = true,
                 extnValue = #'BasicConstraints'{cA = IsCA,
                                                 pathLenConstraint = asn1_NOVALUE}}.

pem(Ders) ->
    public_key:pem_encode([{'Certificate', D, not_encrypted} || D <- Ders]).
