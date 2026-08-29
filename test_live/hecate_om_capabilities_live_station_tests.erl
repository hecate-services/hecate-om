%% Live end-to-end proof for piece B (PLAN_HECATE_OM_MESH_WRAPPERS.md):
%% a capability carrying a `handler' is genuinely CALLABLE mesh-to-mesh
%% via macula_response:advertise_direct, not just discoverable. Run
%% against a real demo-fleet station (station-de-frankfurt.macula.io,
%% confirmed live 2026-08-24 via dig — see project memory
%% reference_demo_fleet_boxes) since macula's own test suite has no
%% local station and defers this exact case to a separate cross-station
%% suite. The demo fleet is documented, disposable dev infra — safe to
%% hit directly (project memory demo_fleet_is_dev_not_prod).
%%
%% This test is what found (and, alongside it, fixed) two real,
%% pre-existing bugs in hecate_om_capabilities, neither introduced by
%% piece B's write-side changes:
%%   1. resolve_at/4 and resolve_full/4 keyed DHT lookups by
%%      procedure_uri/3 (Realm+Org+Name), but a handler-bearing
%%      capability is written under macula_direct_dial's own
%%      discovery_uri/2 key (Realm+bare-Name, no Org — Org is a
%%      post-resolve verify_cert_chain concern in macula's model, per
%%      its own moduledoc). Fixed: discovery_key/2.
%%   2. dial_provider/9 called macula:call_station/7 with no
%%      verify/pin_tls_cert/expected_node_id override, so every direct-
%%      dial call failed at the TLS layer with a generic
%%      `{error, not_connected}' before the application-level trust
%%      check (the DHT record's pubkey signature) ever ran. Fixed by
%%      matching macula_direct_dial:call/6's own documented triad
%%      exactly: `verify => none, pin_tls_cert => false,
%%      expected_node_id => Station'.
%%
%% Lives in test_live/, NOT test/ -- excluded from the default
%% `rebar3 eunit' (and CI's main gate) on purpose: the demo fleet is
%% documented, disposable dev infra with no uptime guarantee, so a
%% station blip must never block an unrelated PR. Run explicitly:
%%   rebar3 as live_test eunit --dir test_live
%% or, for just this module:
%%   rebar3 as live_test eunit --dir test_live --module=hecate_om_capabilities_live_station_tests
-module(hecate_om_capabilities_live_station_tests).
-include_lib("eunit/include/eunit.hrl").

-behaviour(macula_response).
-export([init/1, handle_request/2]).

-define(SEED, <<"https://station-de-frankfurt.macula.io:4433">>).
-define(CAP_NAME, <<"hecate_om_live_test.echo">>).

capability_with_handler_is_genuinely_callable_test_() ->
    {timeout, 30, fun run/0}.

run() ->
    {ok, _} = application:ensure_all_started(macula),
    ProviderKeyPair = macula_identity:generate(#{puzzle => true}),
    Realm = crypto:strong_rand_bytes(32),
    {ok, ProviderPool} = macula_client:connect([?SEED], #{identity => ProviderKeyPair}),
    ok = wait_healthy(ProviderPool, 100),

    {ok, I} = hecate_om_identity:start_link(),
    ok = meck:new(hecate_om_identity, [passthrough]),
    ok = meck:expect(hecate_om_identity, macula_client, fun() -> {ok, ProviderPool} end),
    ok = meck:expect(hecate_om_identity, realm, fun() -> {ok, Realm} end),
    ok = meck:expect(hecate_om_identity, keypair, fun() -> {ok, ProviderKeyPair} end),

    {ok, C} = hecate_om_capabilities:start_link(),
    Cap = #{name => ?CAP_NAME, version => 1, handler => {?MODULE, []}},
    ok = hecate_om_capabilities:register([Cap]),
    Org = hecate_om_identity:org(),

    %% A genuinely separate consumer identity/pool -- provider and
    %% caller are different services in any real deployment.
    ConsumerKeyPair = macula_identity:generate(#{puzzle => true}),
    {ok, ConsumerPool} = macula_client:connect([?SEED], #{identity => ConsumerKeyPair}),
    ok = wait_healthy(ConsumerPool, 100),

    DirectResult = hecate_om_capabilities:call_capability(
                     ConsumerPool, Realm, Org, ?CAP_NAME,
                     #{<<"ping">> => <<"pong">>}, 15_000, #{}),

    meck:unload(hecate_om_identity),
    catch gen_server:stop(C),
    catch gen_server:stop(I),
    catch macula_client:close(ProviderPool),
    catch macula_client:close(ConsumerPool),

    %% Reply keys arrive as atoms, not binaries -- the frame decoder's
    %% documented atom-key round-trip (binary_to_existing_atom/1),
    %% confirmed live here end-to-end; see piece F,
    %% PLAN_HECATE_OM_MESH_WRAPPERS.md.
    ?assertMatch({ok, #{echo := #{ping := <<"pong">>}}}, DirectResult).

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).

%% macula_response callbacks -- a trivial echo, invoked by the station
%% on a real inbound CALL. `Args' (a binary tag) rides through into every
%% reply, which is how org_scoped_call_reaches_only_the_targeted_org_test
%% below tells "acme answered" from "contoso answered" apart live,
%% without needing two separate callback modules for one shared shape.
init(Args) -> {ok, Args}.

handle_request(Payload, Tag) ->
    {reply, #{<<"answered_by">> => Tag, <<"echo">> => Payload}, Tag}.

%%%===================================================================
%%% Two orgs, same bare capability name -- the actual fix this module
%%% exists to prove. Before it, `Org' was accepted by call_capability/5,7
%%% but never reached key derivation (resolve_at/4, resolve_full/4 both
%%% ignored it) -- both orgs' advertisements landed in the same DHT
%%% bucket, and a targeted call could be silently answered by either.
%%% This proves live, against a real station, that a call naming one org
%%% is answered ONLY by that org, every time, never the other.
%%%===================================================================

org_scoped_call_reaches_only_the_targeted_org_test_() ->
    {timeout, 30, fun run_org_scoped/0}.

run_org_scoped() ->
    {ok, _} = application:ensure_all_started(macula),
    Realm = crypto:strong_rand_bytes(32),
    CapName = <<"hecate_om_live_test.org_scoped_echo">>,

    KpAcme    = macula_identity:generate(#{puzzle => true}),
    KpContoso = macula_identity:generate(#{puzzle => true}),
    {ok, PoolAcme}    = macula_client:connect([?SEED], #{identity => KpAcme}),
    {ok, PoolContoso} = macula_client:connect([?SEED], #{identity => KpContoso}),
    ok = wait_healthy(PoolAcme, 100),
    ok = wait_healthy(PoolContoso, 100),

    %% Each provider does exactly what advertise_one/7's handler-bearing
    %% clause now does: register the wire-level handler under the bare
    %% name (advertise_direct), AND separately publish an org-qualified
    %% discovery record (build_advertisement + put_record) at the same
    %% serving station -- reusing the exact same exported functions, not
    %% a hand-rolled substitute for them.
    ok = advertise_org(PoolAcme, Realm, CapName, KpAcme, <<"acme">>, <<"acme">>),
    ok = advertise_org(PoolContoso, Realm, CapName, KpContoso, <<"contoso">>, <<"contoso">>),

    %% ONE consumer pool per call, not one shared pool for both -- found
    %% live 2026-08-29: a SECOND macula:call_station/7 on the same pool
    %% against the same already-connected station fails with
    %% `{disconnected, {peer_closed, "connection lost"}}', reproducibly,
    %% REGARDLESS of which org or procedure is called (confirmed by
    %% calling the same org twice in a row: 1st ok, 2nd fails the same
    %% way). Genuinely unrelated to org-scoped dispatch -- a connection-
    %% layer issue in macula's pool/link reuse, tracked separately; see
    %% PLAN_ORG_SCOPED_DISPATCH_AND_WILDCARD_DISCOVERY.md's cleanup slice
    %% for the follow-up. Two pools sidesteps it without weakening what
    %% THIS test proves (org-targeted CALL dispatch correctness).
    ConsumerKpAcme = macula_identity:generate(#{puzzle => true}),
    {ok, ConsumerPoolAcme} = macula_client:connect([?SEED], #{identity => ConsumerKpAcme}),
    ok = wait_healthy(ConsumerPoolAcme, 100),
    ConsumerKpContoso = macula_identity:generate(#{puzzle => true}),
    {ok, ConsumerPoolContoso} = macula_client:connect([?SEED], #{identity => ConsumerKpContoso}),
    ok = wait_healthy(ConsumerPoolContoso, 100),

    %% Give DHT propagation a moment past the initial writes -- same
    %% retry-tolerant spirit as macula_direct_dial's own resolve loop,
    %% just a fixed pre-sleep here since this test issues both calls
    %% itself rather than looping (find/2's own retry, added 2026-08-29,
    %% is the safety net if this margin is ever too tight).
    timer:sleep(2_000),

    ToAcme = hecate_om_capabilities:call_capability(
               ConsumerPoolAcme, Realm, <<"acme">>, CapName,
               #{<<"who">> => <<"?">>}, 15_000, #{}),
    ToContoso = hecate_om_capabilities:call_capability(
                  ConsumerPoolContoso, Realm, <<"contoso">>, CapName,
                  #{<<"who">> => <<"?">>}, 15_000, #{}),

    catch macula_client:close(PoolAcme),
    catch macula_client:close(PoolContoso),
    catch macula_client:close(ConsumerPoolAcme),
    catch macula_client:close(ConsumerPoolContoso),

    ?assertMatch({ok, #{answered_by := <<"acme">>}}, ToAcme),
    ?assertMatch({ok, #{answered_by := <<"contoso">>}}, ToContoso).

%% Mirrors advertise_one/7's handler-bearing clause (2026-08-29): TWO
%% independent advertise_direct calls, bare name and org_procedure(Org,
%% CapName), each registering its own wire-level handler AND publishing
%% its own DHT record in one call -- no separate build_advertisement/
%% put_record step needed for the org-qualified record any more, since
%% discovery_uri/2 (RealmHex/Procedure) and procedure_uri/3
%% (RealmHex/Org/Name) produce the identical key when
%% Procedure = org_procedure(Org, Name).
advertise_org(Pool, Realm, CapName, KeyPair, Org, ReplyTag) ->
    {ok, SupBare} = macula_response:advertise_direct(Pool, Realm, CapName,
                                                      ?MODULE, ReplyTag, KeyPair, #{}),
    unlink(SupBare),
    OrgProcedure = hecate_om_capabilities:org_procedure(Org, CapName),
    {ok, SupOrg} = macula_response:advertise_direct(Pool, Realm, OrgProcedure,
                                                     ?MODULE, ReplyTag, KeyPair, #{}),
    unlink(SupOrg),
    ok.
