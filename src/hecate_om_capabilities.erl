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
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Pure helpers — the record-building and resolution logic, kept
%% side-effect-free so it is unit-testable without a live mesh.
-export([procedure_uri/2, build_advertisement/4, decode_resolved/1]).

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
                   Caps).

advertise_with({ok, Pool}, {ok, KeyPair}, {ok, Realm}, Caps) ->
    advertise_at(serving_station(Pool), Pool, KeyPair, Realm, Caps);
%% Missing pool / keypair / realm: cannot reach the mesh or sign. No-op;
%% the timer retries once all three are present.
advertise_with(_Pool, _KeyPair, _Realm, _Caps) ->
    ok.

advertise_at({ok, Station}, Pool, KeyPair, Realm, Caps) ->
    _ = [put_advertisement(Pool,
                           build_advertisement(KeyPair, Realm, Cap, Station))
         || Cap <- Caps],
    ok;
advertise_at({error, no_station}, _Pool, _KeyPair, _Realm, _Caps) ->
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
                 hecate_om_identity:realm(), CapName).

resolve_with({ok, Pool}, {ok, Realm}, CapName) ->
    Key = macula_record:procedure_key(procedure_uri(Realm, CapName)),
    resolve_records(find(Pool, Key));
resolve_with(_Pool, _Realm, _CapName) ->
    [].

resolve_records({ok, Records}) -> decode_resolved(Records);
resolve_records(_Other)        -> [].

find(Pool, Key) ->
    try macula:find_records(Pool, Key)
    catch _:_ -> {error, unreachable}
    end.

%%% Pure helpers (unit-tested)

%% Realm-namespaced procedure URI. The org segment (Q8) rides with
%% Slice 7 trust; realm-scoping is enough for discovery and
%% cross-realm collision-freedom now.
-spec procedure_uri(binary(), binary() | map()) -> binary().
procedure_uri(Realm, #{name := Name}) ->
    procedure_uri(Realm, Name);
procedure_uri(Realm, Name) when is_binary(Realm), is_binary(Name) ->
    <<(binary:encode_hex(Realm))/binary, "/", Name/binary>>.

-spec build_advertisement(macula_identity:key_pair(), binary(),
                          hecate_om_service:capability(),
                          macula_identity:pubkey()) -> map().
build_advertisement(KeyPair, Realm, #{name := Name}, Station) ->
    Advertiser = macula_identity:public(KeyPair),
    Uri        = procedure_uri(Realm, Name),
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
