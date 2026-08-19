%%% @doc Advertises a service's capabilities as signed procedure
%%% advertisements in the mesh DHT, and resolves other services'
%%% capabilities from the same DHT.
%%%
%%% Replaces the former pubsub `_mesh.cap.announce' summary broadcast:
%%% discovery is record-based now (direct-dial discovery, plan Slice 2).
%%% For each capability the service exposes, this worker writes a signed
%%% `procedure_advertisement' keyed at `SHA-256(procedure_uri)', naming
%%% the service (advertiser) and one station it is reachable through
%%% (serving_station). Records are re-asserted on a timer because DHT
%%% records expire (and the timer also retries the initial write until
%%% the pool and a station link are up).
%%%
%%% `lookup/1' resolves a capability by name: derive the same procedure
%%% key, read every advertisement stored there, verify each signature,
%%% return the `{advertiser, serving_station}' set. A consumer then dials
%%% one of those stations (Slice 4+).
%%%
%%% Signing needs the service's stable keypair
%%% (`hecate_om_identity:keypair/0'); an ephemeral service cannot sign
%%% and is correctly not advertised.
-module(hecate_om_capabilities).
-behaviour(gen_server).

-export([start_link/0, register/1, publish/0, lookup/1, list/0]).
-export([call_capability/5, call_capability/7]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Pure helpers — the record-building and resolution logic, kept
%% side-effect-free so it is unit-testable without a live mesh.
-export([procedure_uri/3, build_advertisement/5, decode_resolved/1,
         station_url/2]).

%% Re-assert advertisements this often. Records outlive one interval;
%% the tick also retries the initial write until the pool + a station
%% link are present.
-define(REPUBLISH_INTERVAL_MS, 30_000).

-record(state, {
    capabilities = []        :: [hecate_om_service:capability()],
    timer        = undefined :: reference() | undefined
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Caps) when is_list(Caps) ->
    gen_server:call(?MODULE, {register, Caps}).

publish() ->
    gen_server:call(?MODULE, publish).

%% @doc Resolve a capability by name to the providers advertising it.
%% `{ok, [#{advertiser := Pubkey, serving_station := Pubkey}]}'. Empty
%% when nothing is advertised or the mesh is unreachable.
-spec lookup(binary()) -> {ok, [map()]}.
lookup(CapName) when is_binary(CapName) ->
    gen_server:call(?MODULE, {lookup, CapName}).

%% @doc Call a capability by name over the DIRECT-DIAL data path: resolve
%% the providers of `CapName' (their `procedure_advertisement' records),
%% resolve one provider's serving station to a dialable endpoint, dial it
%% directly and issue the CALL there. On failure (unresolvable endpoint,
%% dead station, error reply) fail over to the next provider.
%%
%% The CALL uses the raw `CapName' as the procedure (realm-scoped by
%% `Realm'), matching how a provider serves it via `macula:advertise'.
%% Runs in the caller's process (not the capabilities gen_server), so a
%% slow mesh never blocks capability registration.
-spec call_capability(binary(), binary(), term(), pos_integer(), map()) ->
    {ok, term()} | {error, term()}.
call_capability(Org, CapName, Payload, TimeoutMs, Opts)
  when is_binary(Org), is_binary(CapName),
       is_integer(TimeoutMs), TimeoutMs > 0, is_map(Opts) ->
    call_capability_via(hecate_om_identity:macula_client(),
                        hecate_om_identity:realm(),
                        Org, CapName, Payload, TimeoutMs, Opts).

list() ->
    gen_server:call(?MODULE, list).

%%% gen_server

init([]) ->
    {ok, arm_timer(#state{})}.

handle_call({register, Caps}, _From, S) ->
    do_advertise(Caps),
    {reply, ok, S#state{capabilities = Caps}};

handle_call(publish, _From, #state{capabilities = Caps} = S) ->
    do_advertise(Caps),
    {reply, ok, S};

handle_call({lookup, CapName}, _From, S) ->
    {reply, {ok, do_resolve(CapName)}, S};

handle_call(list, _From, #state{capabilities = Caps} = S) ->
    {reply, Caps, S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(republish, #state{capabilities = Caps} = S) ->
    do_advertise(Caps),
    {noreply, arm_timer(S)};
handle_info(_Other, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%% Internals — advertise (write records)

do_advertise([]) ->
    ok;
do_advertise(Caps) ->
    advertise_with(hecate_om_identity:macula_client(),
                   hecate_om_identity:keypair(),
                   hecate_om_identity:realm(),
                   hecate_om_identity:org(),
                   Caps).

advertise_with({ok, Pool}, {ok, KeyPair}, {ok, Realm}, Org, Caps) ->
    advertise_at(serving_station(Pool), Pool, KeyPair, Realm, Org, Caps);
%% Missing pool / keypair / realm: cannot reach the mesh or sign. No-op;
%% the timer retries once all three are present.
advertise_with(_Pool, _KeyPair, _Realm, _Org, _Caps) ->
    ok.

advertise_at({ok, Station}, Pool, KeyPair, Realm, Org, Caps) ->
    _ = [put_advertisement(Pool,
                           build_advertisement(KeyPair, Realm, Org, Cap, Station))
         || Cap <- Caps],
    ok;
advertise_at({error, no_station}, _Pool, _KeyPair, _Realm, _Org, _Caps) ->
    ok.

put_advertisement(Pool, Record) ->
    try macula:put_record(Pool, Record)
    catch _:_ -> ok
    end.

%% One station this service is reachable through, from the pool's
%% connected links. Slice 2 advertises ONE serving station per provider
%% (the store dedups records by signer); multi-station is Q10 / Slice 5.
serving_station(Pool) ->
    case connected_node_ids(Pool) of
        [NodeId | _] -> {ok, NodeId};
        []           -> {error, no_station}
    end.

connected_node_ids(Pool) ->
    try macula:links(Pool) of
        {ok, Links} ->
            [NodeId || #{connected := true, node_id := NodeId} <- Links,
                       is_binary(NodeId)];
        _ ->
            []
    catch _:_ ->
        []
    end.

%%% Internals — resolve (read records)

do_resolve(CapName) ->
    resolve_with(hecate_om_identity:macula_client(),
                 hecate_om_identity:realm(),
                 hecate_om_identity:org(), CapName).

resolve_with({ok, Pool}, {ok, Realm}, Org, CapName) ->
    resolve_at(Pool, Realm, Org, CapName);
resolve_with(_Pool, _Realm, _Org, _CapName) ->
    [].

resolve_at(Pool, Realm, Org, CapName) ->
    Key = macula_record:procedure_key(procedure_uri(Realm, Org, CapName)),
    resolve_records(find(Pool, Key)).

resolve_records({ok, Records}) -> decode_resolved(Records);
resolve_records(_Other)        -> [].

find(Pool, Key) ->
    try macula:find_records(Pool, Key)
    catch _:_ -> {error, unreachable}
    end.

%%% Internals — call a capability (resolve -> verify -> dial -> call)

call_capability_via({ok, Pool}, {ok, Realm}, Org, CapName, Payload,
                    TimeoutMs, Opts) ->
    call_capability(Pool, Realm, Org, CapName, Payload, TimeoutMs, Opts);
call_capability_via(_Pool, _Realm, _Org, _CapName, _Payload, _TimeoutMs, _Opts) ->
    {error, not_configured}.

%% @doc Explicit-pool form (testable without hecate_om_identity).
%% `Opts': `verify => boolean()' (default false = open; when true, drop
%% providers whose realm -> org -> server delegation chain does not
%% verify, Slice 7c) and `ucan_token => binary()' (presented to a gated
%% provider, Slice 7b).
-spec call_capability(pid(), binary(), binary(), binary(), term(),
                      pos_integer(), map()) -> {ok, term()} | {error, term()}.
call_capability(Pool, Realm, Org, CapName, Payload, TimeoutMs, Opts) ->
    Providers = verify_providers(maps:get(verify, Opts, false),
                                 Pool, Realm, Org,
                                 resolve_at(Pool, Realm, Org, CapName)),
    call_providers(Providers, Pool, Realm, CapName, Payload, TimeoutMs,
                   maps:get(ucan_token, Opts, <<>>)).

%% Verifying-consumer mode (7c): keep only providers whose advertisement
%% chains realm -> org -> server. Open mode (default): keep all.
verify_providers(false, _Pool, _Realm, _Org, Providers) ->
    Providers;
verify_providers(true, Pool, Realm, Org, Providers) ->
    [P || P <- Providers, chain_verifies(Pool, Realm, Org, P)].

chain_verifies(Pool, Realm, Org, #{advertiser := Adv}) ->
    with_org_directory(
      find_record(Pool, macula_record:org_directory_key(Realm, Org)),
      Pool, Realm, Adv).

with_org_directory({ok, OrgDir}, Pool, Realm, Adv) ->
    #{org_key := OrgKey} = macula_record:read_org_directory(OrgDir),
    with_delegation(
      find_record(Pool, macula_record:procedure_delegation_key(OrgKey, Adv)),
      Realm, OrgDir, Adv);
with_org_directory(_Miss, _Pool, _Realm, _Adv) ->
    false.

with_delegation({ok, Del}, Realm, OrgDir, Adv) ->
    macula_record:verify_delegation_chain(Realm, OrgDir, Del, Adv) =:= ok;
with_delegation(_Miss, _Realm, _OrgDir, _Adv) ->
    false.

call_providers([], _Pool, _Realm, _CapName, _Payload, _TimeoutMs, _Ucan) ->
    {error, no_provider};
call_providers([#{serving_station := Station} | Rest],
               Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    dial_provider(resolve_endpoint(Pool, Station),
                  Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan).

%% Endpoint resolved: dial + call; on error, fail over to the next.
dial_provider({ok, Url}, Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    failover(macula:call_station(Pool, Url, Realm, CapName, Payload, TimeoutMs,
                                 #{ucan_token => Ucan}),
             Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan);
dial_provider({error, _}, Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    call_providers(Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan).

failover({ok, _} = Ok, _R, _P, _Rlm, _Cap, _Pl, _Tmo, _Ucan) ->
    Ok;
failover({error, _}, Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    call_providers(Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan).

%% Resolve a serving_station pubkey to a dialable `quic://' URL via its
%% signed `station_endpoint' record.
resolve_endpoint(Pool, Station) ->
    endpoint_url(find_endpoint(Pool, Station)).

find_endpoint(Pool, Station) ->
    read_endpoint(find_record(Pool, macula_record:station_endpoint_key(Station))).

find_record(Pool, Key) ->
    try macula:find_record(Pool, Key)
    catch _:_ -> {error, unreachable}
    end.

read_endpoint({ok, Record}) ->
    {ok, macula_record:read_station_endpoint(Record)};
read_endpoint(_Other) ->
    {error, no_endpoint}.

endpoint_url({ok, #{quic_port := Port, host_advertised := [Host | _]}}) ->
    {ok, station_url(Host, Port)};
endpoint_url(_Other) ->
    {error, no_endpoint}.

%%% Pure helpers (unit-tested)

%% Realm-namespaced procedure URI. The org segment (Q8) rides with
%% Slice 7 trust; realm-scoping is enough for discovery and
%% cross-realm collision-freedom now.
%% `<realm-hex>/<org>/<capability>' — the org segment (Slice 7c) roots
%% the delegation chain and keeps two orgs' same-named capabilities
%% distinct.
-spec procedure_uri(binary(), binary(), binary() | map()) -> binary().
procedure_uri(Realm, Org, #{name := Name}) ->
    procedure_uri(Realm, Org, Name);
procedure_uri(Realm, Org, Name)
  when is_binary(Realm), is_binary(Org), is_binary(Name) ->
    <<(binary:encode_hex(Realm))/binary, "/", Org/binary, "/", Name/binary>>.

%% Build the `quic://' seed URL a pool dials, bracketing IPv6 hosts.
-spec station_url(binary(), 1..65535) -> binary().
station_url(Host, Port) when is_binary(Host), is_integer(Port) ->
    HostPart = bracket_if_ipv6(Host),
    <<"quic://", HostPart/binary, ":", (integer_to_binary(Port))/binary>>.

bracket_if_ipv6(Host) ->
    add_brackets(binary:match(Host, <<":">>), Host).

add_brackets(nomatch, Host) -> Host;
add_brackets(_Found, Host)  -> <<"[", Host/binary, "]">>.

-spec build_advertisement(macula_identity:key_pair(), binary(), binary(),
                          hecate_om_service:capability(),
                          macula_identity:pubkey()) -> map().
build_advertisement(KeyPair, Realm, Org, #{name := Name}, Station) ->
    Advertiser = macula_identity:public(KeyPair),
    Uri        = procedure_uri(Realm, Org, Name),
    Record     = macula_record:procedure_advertisement(Advertiser, Uri, Station),
    macula_record:sign(Record, KeyPair).

%% Verify each record's signature and project it to
%% `{advertiser, serving_station}'. Non-procedure records and bad
%% signatures are dropped. (Full trust-chain checking is Slice 7; this
%% is the authenticity floor.)
-spec decode_resolved([map()]) -> [map()].
decode_resolved(Records) ->
    lists:filtermap(fun decode_one/1, Records).

decode_one(Record) ->
    decode_verified(macula_record:verify(Record), Record).

decode_verified({ok, _Payload}, Record) ->
    try macula_record:read_procedure_advertisement(Record) of
        #{advertiser_node := Adv, serving_station := Sta} ->
            {true, #{advertiser => Adv, serving_station => Sta}}
    catch _:_ ->
        false
    end;
decode_verified({error, _}, _Record) ->
    false.

%%% Timer

arm_timer(S) ->
    Ref = erlang:send_after(?REPUBLISH_INTERVAL_MS, self(), republish),
    S#state{timer = Ref}.
