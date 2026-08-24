%%% @doc Advertises a service's capabilities on the mesh, and resolves
%%% other services' capabilities from the DHT.
%%%
%%% A capability carrying `handler => {HandlerModule, Args}' is advertised
%%% via `macula_response:advertise_direct/7' — the SDK's own supervised
%%% wrapper, which registers the handler with the pool AND publishes the
%%% signed `procedure_advertisement' DHT record naming this pool's
%%% connected station, in one call. This module used to hand-build that
%%% same record type itself (`build_advertisement/5,6' + `put_record')
%%% without ever registering a handler — discoverable, but not callable
%%% (the gap the 2026-08-21 survey confirmed; see
%%% `hecate-om/plans/PLAN_HECATE_OM_MESH_WRAPPERS.md', piece B). A
%%% capability with no `handler' key still gets that legacy record-only
%%% path, kept for backward compatibility with a capability another
%%% mechanism serves.
%%%
%%% `reuse_sup/0''s pid is round-tripped through this worker's state and
%%% passed back in as `advertise_direct's own `reuse_sup' option on every
%%% 30s republish tick — a station's wire-level registration for a
%%% procedure is tied to the connection that sent it and does not survive
%%% that connection being replaced (see `macula_response:advertise_direct/7'
%%% and `hecate-tube''s `tube_mesh_providers.erl', which hit this bug
%%% live before this option existed); periodic re-advertise without
%%% `reuse_sup' would also leak one factory supervisor per tick.
%%%
%%% `lookup/1' resolves a capability by name: derive the same procedure
%%% key, read every advertisement stored there, verify each signature,
%%% return the `{advertiser, serving_station}' set. A consumer then dials
%%% one of those stations (Slice 4+) — unchanged by the handler-vs-record-
%%% only split above, since both paths write the same record shape.
%%%
%%% Signing needs the service's stable keypair
%%% (`hecate_om_identity:keypair/0'); an ephemeral service cannot sign
%%% and is correctly not advertised.
-module(hecate_om_capabilities).
-behaviour(gen_server).

-export([start_link/0, register/1, publish/0, lookup/1, list/0]).
-export([call_capability/5, call_capability/7]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Pure helpers — the record-building, dispatch-decision, and resolution
%% logic, kept side-effect-free so it is unit-testable without a live
%% mesh.
-export([procedure_uri/3, build_advertisement/5, build_advertisement/6,
         decode_resolved/1, station_url/2, has_handler/1, reuse_sup_opts/1,
         discovery_key/2]).

%% Re-assert advertisements this often. Records outlive one interval;
%% the tick also retries the initial write until the pool + a station
%% link are present.
-define(REPUBLISH_INTERVAL_MS, 30_000).

-record(state, {
    capabilities   = []        :: [hecate_om_service:capability()],
    timer          = undefined :: reference() | undefined,
    %% Capability name -> factory supervisor pid from a prior
    %% advertise_direct/7 call. Passed back in as `reuse_sup' on the
    %% next tick for that capability; see moduledoc.
    advertise_sups = #{}       :: #{binary() => pid()}
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

handle_call({register, Caps}, _From, #state{advertise_sups = Sups} = S) ->
    NewSups = do_advertise(Caps, Sups),
    {reply, ok, S#state{capabilities = Caps, advertise_sups = NewSups}};

handle_call(publish, _From, #state{capabilities = Caps,
                                   advertise_sups = Sups} = S) ->
    NewSups = do_advertise(Caps, Sups),
    {reply, ok, S#state{advertise_sups = NewSups}};

handle_call({lookup, CapName}, _From, S) ->
    {reply, {ok, do_resolve(CapName)}, S};

handle_call(list, _From, #state{capabilities = Caps} = S) ->
    {reply, Caps, S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(republish, #state{capabilities = Caps,
                              advertise_sups = Sups} = S) ->
    NewSups = do_advertise(Caps, Sups),
    {noreply, arm_timer(S#state{advertise_sups = NewSups})};
handle_info(_Other, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%% Internals — advertise (write records / register handlers)

do_advertise(Caps, Sups) ->
    advertise_with(hecate_om_identity:macula_client(),
                   hecate_om_identity:keypair(),
                   hecate_om_identity:realm(),
                   hecate_om_identity:org(),
                   cert_chain_opts(hecate_om_identity:cert_chain()),
                   Caps, Sups).

%% Embed the service cert chain when one is provisioned (Slice 7c
%% Direction B); otherwise advertise without it (open-mode discovery).
cert_chain_opts({ok, Pem})  -> #{cert_chain => Pem};
cert_chain_opts({error, _}) -> #{}.

advertise_with({ok, Pool}, {ok, KeyPair}, {ok, Realm}, Org, CertOpts, Caps, Sups) ->
    lists:foldl(fun(Cap, Acc) ->
                    advertise_one(Pool, KeyPair, Realm, Org, CertOpts, Cap, Acc)
                end, Sups, Caps);
%% Missing pool / keypair / realm: cannot reach the mesh or sign. No-op;
%% the timer retries once all three are present. Existing sups (if any)
%% are kept as-is — a transient mesh gap does not invalidate them.
advertise_with(_Pool, _KeyPair, _Realm, _Org, _CertOpts, _Caps, Sups) ->
    Sups.

%% @doc Whether `Cap' carries a handler (and so should be advertised via
%% `advertise_direct', not just written to the DHT as a bare discovery
%% record).
-spec has_handler(hecate_om_service:capability()) -> boolean().
has_handler(#{handler := _}) -> true;
has_handler(_) -> false.

advertise_one(Pool, KeyPair, Realm, _Org, CertOpts,
             #{name := Name, handler := {Mod, Args}}, Sups) ->
    %% Procedure MUST be the bare capability name, not procedure_uri/3's
    %% Realm+Org+Name form: hecate_om_capabilities:call_capability/7
    %% dials via macula:call_station(..., CapName, ...) -- the bare
    %% name -- so the wire-level ADVERTISE registration this creates
    %% has to match that exactly, or a resolved provider would never
    %% actually answer a CALL. macula_response:advertise_direct wraps
    %% `Name' with Realm itself (macula_direct_dial's own
    %% discovery_uri/2, "no Org segment... Org is only consulted
    %% post-resolve") for the DHT record — matched on the read side by
    %% discovery_key/2 below, not by procedure_uri/3.
    Opts = maps:merge(CertOpts, reuse_sup_opts(maps:get(Name, Sups, undefined))),
    advertised(macula_response:advertise_direct(Pool, Realm, Name, Mod, Args,
                                                KeyPair, Opts),
              Name, Sups);
advertise_one(Pool, KeyPair, Realm, Org, CertOpts, Cap, Sups) ->
    %% No handler declared — legacy discoverable-but-not-callable path,
    %% kept for a capability another mechanism serves.
    advertise_record_only(serving_station(Pool), Pool, KeyPair, Realm, Org,
                          CertOpts, Cap),
    Sups.

%% @doc The extra `Opts' entry an `advertise_direct' retry needs to reuse
%% a prior call's factory supervisor instead of leaking a new one every
%% republish tick. `#{}' on a capability's first-ever advertise.
-spec reuse_sup_opts(pid() | undefined) -> map().
reuse_sup_opts(undefined)            -> #{};
reuse_sup_opts(Sup) when is_pid(Sup) -> #{reuse_sup => Sup}.

advertised({ok, Sup}, Name, Sups)   -> Sups#{Name => Sup};
advertised({error, _Reason}, _Name, Sups) -> Sups.

advertise_record_only({ok, Station}, Pool, KeyPair, Realm, Org, CertOpts, Cap) ->
    put_advertisement(Pool, build_advertisement(KeyPair, Realm, Org, Cap,
                                                Station, CertOpts));
advertise_record_only({error, no_station}, _Pool, _KeyPair, _Realm, _Org,
                      _CertOpts, _Cap) ->
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

resolve_at(Pool, Realm, _Org, CapName) ->
    resolve_records(find(Pool, discovery_key(Realm, CapName))).

%% The key a handler-bearing capability is actually reachable under:
%% Realm + the bare capability name, matching macula_direct_dial's own
%% (private, so replicated here) discovery_uri/2 formula -- NOT
%% procedure_uri/3, whose Org segment matches nothing advertise_direct
%% itself ever produces (see advertise_one/7). A capability advertised
%% via the legacy record-only path (no handler, never callable via
%% call_capability regardless) is not resolvable through this lookup —
%% documented as written "for a capability another mechanism serves".
discovery_key(Realm, Name) ->
    macula_record:procedure_key(<<(binary:encode_hex(Realm))/binary, "/",
                                  Name/binary>>).

resolve_records({ok, Records}) -> decode_resolved(Records);
resolve_records(_Other)        -> [].

%% Like resolve_at/4 but keeps each raw record so the verifying-consumer
%% path (7c Direction B) can chain-check the embedded service cert.
resolve_full(Pool, Realm, _Org, CapName) ->
    resolve_full_records(find(Pool, discovery_key(Realm, CapName))).

resolve_full_records({ok, Records}) -> decode_resolved_full(Records);
resolve_full_records(_Other)        -> [].

decode_resolved_full(Records) ->
    lists:filtermap(fun decode_one_full/1, Records).

decode_one_full(Record) ->
    decode_verified_full(macula_record:verify(Record), Record).

decode_verified_full({ok, _Payload}, Record) ->
    try macula_record:read_procedure_advertisement(Record) of
        #{advertiser_node := Adv, serving_station := Sta} ->
            {true, #{advertiser => Adv, serving_station => Sta, record => Record}}
    catch _:_ ->
        false
    end;
decode_verified_full({error, _}, _Record) ->
    false.

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
%% providers whose embedded service-cert chain does not verify to the
%% realm CA, Slice 7c Direction B) and `ucan_token => binary()'
%% (presented to a gated provider, Slice 7b).
-spec call_capability(pid(), binary(), binary(), binary(), term(),
                      pos_integer(), map()) -> {ok, term()} | {error, term()}.
call_capability(Pool, Realm, Org, CapName, Payload, TimeoutMs, Opts) ->
    Providers = verify_providers(maps:get(verify, Opts, false), Org,
                                 resolve_full(Pool, Realm, Org, CapName)),
    call_providers(Providers, Pool, Realm, CapName, Payload, TimeoutMs,
                   maps:get(ucan_token, Opts, <<>>)).

%% Verifying-consumer mode (7c Direction B): keep only providers whose
%% embedded service-cert chain verifies to the realm CA and whose leaf
%% is issued for `Org'. Open mode (default): keep all.
verify_providers(false, _Org, Providers) ->
    Providers;
verify_providers(true, Org, Providers) ->
    keep_chain_verified(hecate_om_identity:realm_ca(), Org, Providers).

%% `verify => true' but no realm CA provisioned: nothing can be verified,
%% so drop every provider rather than trust blindly.
keep_chain_verified({ok, RealmCaPem}, Org, Providers) ->
    [P || #{record := Rec} = P <- Providers,
          macula_record:verify_advertisement_cert_chain(RealmCaPem, Rec, Org)
              =:= ok];
keep_chain_verified({error, _}, _Org, _Providers) ->
    [].

call_providers([], _Pool, _Realm, _CapName, _Payload, _TimeoutMs, _Ucan) ->
    {error, no_provider};
call_providers([#{serving_station := Station} | Rest],
               Pool, Realm, CapName, Payload, TimeoutMs, Ucan) ->
    dial_provider(resolve_endpoint(Pool, Station), Station,
                  Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan).

%% Endpoint resolved: dial + call; on error, fail over to the next.
%%
%% Trust triad matches macula_direct_dial:call/6 exactly (verified
%% against a real demo-fleet station, 2026-08-24 -- omitting it makes
%% every direct-dial call fail with `not_connected', not a signature
%% or auth error, because the failure is at the TLS layer before the
%% application-level trust check ever runs): a resolved provider is
%% trusted because the signed DHT `procedure_advertisement' chain
%% named exactly this `Station' pubkey, not because its TLS
%% certificate chains to a CA -- a production station's TLS cert has
%% no relationship to its macula identity. `verify => none' +
%% `pin_tls_cert => false' skip the (irrelevant) TLS check;
%% `expected_node_id => Station' is what actually pins trust, enforced
%% at the application layer during the CONNECT/HELLO handshake.
dial_provider({ok, Url}, Station, Rest, Pool, Realm, CapName, Payload,
              TimeoutMs, Ucan) ->
    CallResult = macula:call_station(Pool, Url, Realm, CapName, Payload,
                                     TimeoutMs,
                                     #{ucan_token => Ucan,
                                       expected_node_id => Station,
                                       pin_tls_cert => false,
                                       verify => none}),
    failover(CallResult, Rest, Pool, Realm, CapName, Payload, TimeoutMs, Ucan);
dial_provider({error, _}, _Station, Rest, Pool, Realm, CapName, Payload,
              TimeoutMs, Ucan) ->
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
build_advertisement(KeyPair, Realm, Org, Cap, Station) ->
    build_advertisement(KeyPair, Realm, Org, Cap, Station, #{}).

%% `CertOpts' carries `cert_chain => Pem' (leaf ++ org CA) so a verifying
%% consumer can chain the advertiser to the realm CA (Slice 7c Direction B);
%% `#{}' when the service has no provisioned chain.
-spec build_advertisement(macula_identity:key_pair(), binary(), binary(),
                          hecate_om_service:capability(),
                          macula_identity:pubkey(),
                          macula_record:procedure_advertisement_opts()) -> map().
build_advertisement(KeyPair, Realm, Org, #{name := Name}, Station, CertOpts) ->
    Advertiser = macula_identity:public(KeyPair),
    Uri        = procedure_uri(Realm, Org, Name),
    Record     = macula_record:procedure_advertisement(Advertiser, Uri, Station,
                                                       CertOpts),
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
