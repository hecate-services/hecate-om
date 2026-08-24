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
%% Runs as part of the default `rebar3 eunit' (rebar3 has no built-in
%% way to exclude one test/*.erl module from discovery without moving
%% it out of test/ entirely) -- it's fast (~1s against a responsive
%% station) and this repo already treats the demo fleet as safe,
%% disposable dev infra, so that's an acceptable tradeoff for now, not
%% an oversight. If this becomes flaky in CI (the demo fleet is not
%% guaranteed uptime), move it to a separate directory + eunit profile
%% rather than deleting the coverage. Run just this module directly:
%%   rebar3 eunit --module=hecate_om_capabilities_live_station_tests
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
%% on a real inbound CALL.
init(_Args) -> {ok, []}.

handle_request(Payload, State) ->
    {reply, #{<<"echo">> => Payload}, State}.
