%%% @doc Loads the service-principal cert at boot and a Macula SDK
%%% client handle. Held in a gen_server so every other process can
%%% borrow the pool through `hecate_om:macula_client/0'.
%%%
%%% Each hecate-service has its OWN realm-signed credential (NOT a
%%% user's). The credential lives at /etc/hecate/secrets/service-cert.pem
%%% inside the container; the host mounts the per-service directory
%%% from `/etc/hecate/secrets/<service-name>/' onto that path.
%%%
%%% v1: long-lived realm-signed cert provisioned out-of-band by a
%%% realm-admin script. v2: short-lived UCAN auto-rotated from a
%%% realm HTTP endpoint. The v2 swap-in lands here without touching
%%% consumers.
%%%
%%% Connect-degradation: when seeds aren't reachable (early boot,
%%% test harness, no station nearby), `macula_client/0' returns
%%% `{error, no_client}' and consumers should fall back to no-op
%%% behaviour. The service stays up; it just doesn't talk to the mesh.
-module(hecate_om_identity).
-behaviour(gen_server).

-export([start_link/0, service_cert/0, macula_client/0, realm/0, keypair/0,
         org/0, cert_chain/0, realm_ca/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% Exported for hecate_om_identity_tests.erl -- pure resolution logic,
%% same testing convention hecate_om_capabilities.erl already uses.
-export([keypair_from/1]).

-record(state, {
    cert      :: binary() | undefined,
    client    :: pid()    | undefined,
    realm     :: binary() | undefined,  %% 32-byte realm tag
    %% Stable service keypair, loaded from `identity_key_path' at boot
    %% and RETAINED so the service can sign its own DHT records
    %% (procedure_advertisement). Undefined when the service runs on an
    %% ephemeral SDK identity — such a service peers and calls fine but
    %% cannot sign records, so it is (correctly) invisible to DHT
    %% discovery.
    keypair   :: macula_identity:key_pair() | undefined,
    %% This service's org name (the `<org>' segment of its procedure
    %% URIs, and the delegation-chain root below the realm). From the
    %% `org' app env; defaults to `<<"_">>' when unset. Direct-dial
    %% dual-trust (Slice 7c).
    org       :: binary(),
    %% Direct-dial dual-trust (Slice 7c Direction B). `org_ca' is the org
    %% CA that issued this service's leaf cert; leaf ++ org CA is embedded
    %% in advertisements so a consumer can chain to the realm CA. `realm_ca'
    %% is the trust anchor a verifying consumer checks resolved
    %% advertisements against. Both provisioned onto disk beside the leaf
    %% cert; `undefined' when absent (service then advertises without a
    %% chain / cannot run `verify => true').
    org_ca    :: binary() | undefined,
    realm_ca  :: binary() | undefined
}).

%% Retry cadence for (re)attaching the mesh pool.
-define(RECONNECT_MS, 5000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

service_cert() ->
    gen_server:call(?MODULE, service_cert).

macula_client() ->
    gen_server:call(?MODULE, macula_client).

realm() ->
    gen_server:call(?MODULE, realm).

%% @doc The service's stable signing keypair, or `{error, no_keypair}'
%% when running on an ephemeral identity. Callers that sign DHT records
%% degrade to no-op on the error.
-spec keypair() -> {ok, macula_identity:key_pair()} | {error, no_keypair}.
keypair() ->
    gen_server:call(?MODULE, keypair).

%% @doc This service's org name (the `<org>' segment of its procedure
%% URIs). Always a binary; `<<"_">>' when unconfigured.
-spec org() -> binary().
org() ->
    gen_server:call(?MODULE, org).

%% @doc The cert chain to embed in advertisements: this service's leaf
%% cert followed by its org CA (PEM). `{error, no_cert_chain}' when
%% either half is missing — the service then advertises without a chain
%% and is reachable only by open-mode consumers (Slice 7c Direction B).
-spec cert_chain() -> {ok, binary()} | {error, no_cert_chain}.
cert_chain() ->
    gen_server:call(?MODULE, cert_chain).

%% @doc The realm CA a verifying consumer trusts as the direct-dial
%% trust anchor (PEM). `{error, no_realm_ca}' when unconfigured — a
%% `verify => true' call then cannot verify and drops every provider.
-spec realm_ca() -> {ok, binary()} | {error, no_realm_ca}.
realm_ca() ->
    gen_server:call(?MODULE, realm_ca).

init([]) ->
    Cert  = case load_cert() of
        {ok, C}    -> C;
        {error, _} -> undefined
    end,
    Realm   = load_realm(),
    KeyPair = load_keypair(),
    Org     = load_org(),
    %% Connect off the init path and retry. At boot hecate_om may start
    %% before the macula SDK app is fully up, so a single inline connect
    %% races it and loses (the bug that kept services dark even with seeds).
    %% handle_info(connect) attempts + reschedules until a pool attaches,
    %% and re-attaches if the pool later dies.
    self() ! connect,
    {ok, #state{cert = Cert, client = undefined, realm = Realm,
                keypair = KeyPair, org = Org,
                org_ca = load_org_ca(), realm_ca = load_realm_ca()}}.

handle_call(service_cert, _From, #state{cert = undefined} = S) ->
    {reply, {error, no_cert}, S};
handle_call(service_cert, _From, #state{cert = C} = S) ->
    {reply, {ok, C}, S};

handle_call(macula_client, _From, #state{client = undefined} = S) ->
    {reply, {error, no_client}, S};
handle_call(macula_client, _From, #state{client = Pid} = S) ->
    {reply, {ok, Pid}, S};

handle_call(realm, _From, #state{realm = undefined} = S) ->
    {reply, {error, no_realm}, S};
handle_call(realm, _From, #state{realm = R} = S) ->
    {reply, {ok, R}, S};

handle_call(keypair, _From, #state{keypair = undefined} = S) ->
    {reply, {error, no_keypair}, S};
handle_call(keypair, _From, #state{keypair = Kp} = S) ->
    {reply, {ok, Kp}, S};

handle_call(org, _From, #state{org = Org} = S) ->
    {reply, Org, S};

handle_call(cert_chain, _From, #state{cert = C, org_ca = O} = S)
  when is_binary(C), is_binary(O) ->
    {reply, {ok, <<C/binary, "\n", O/binary>>}, S};
handle_call(cert_chain, _From, S) ->
    {reply, {error, no_cert_chain}, S};

handle_call(realm_ca, _From, #state{realm_ca = undefined} = S) ->
    {reply, {error, no_realm_ca}, S};
handle_call(realm_ca, _From, #state{realm_ca = RC} = S) ->
    {reply, {ok, RC}, S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(connect, #state{client = undefined, keypair = Kp} = S) ->
    case attach_client(Kp) of
        undefined ->
            erlang:send_after(?RECONNECT_MS, self(), connect),
            {noreply, S};
        Pool ->
            _ = is_pid(Pool) andalso erlang:monitor(process, Pool),
            {noreply, S#state{client = Pool}}
    end;
handle_info(connect, S) ->
    %% Already connected.
    {noreply, S};
handle_info({'DOWN', _Ref, process, Pool, _Reason}, #state{client = Pool} = S) ->
    %% The mesh pool died — drop it and reconnect.
    self() ! connect,
    {noreply, S#state{client = undefined}};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _State) -> ok.

%%% Internals

load_cert() ->
    Path = application:get_env(hecate_om, service_cert_path,
                               "/etc/hecate/secrets/service-cert.pem"),
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        Err       -> Err
    end.

%% Org CA and realm CA (Slice 7c Direction B), provisioned onto disk
%% beside the leaf cert. Absent = `undefined' (advertise without a
%% chain / no `verify => true').
load_org_ca() ->
    read_pem(application:get_env(hecate_om, org_ca_cert_path,
                                 "/etc/hecate/secrets/org-ca.pem")).

load_realm_ca() ->
    read_pem(application:get_env(hecate_om, realm_ca_cert_path,
                                 "/etc/hecate/secrets/realm-ca.pem")).

read_pem(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        _         -> undefined
    end.

%% @doc Realm tag = 32-byte binary. v1: read from env (operator
%% pins it via `hecate-gitops/system/<service>.env'). v2: extract
%% from the service-principal cert at boot.
load_realm() ->
    case application:get_env(hecate_om, realm) of
        {ok, R} when is_binary(R), byte_size(R) =:= 32 ->
            R;
        {ok, HexB} when is_binary(HexB), byte_size(HexB) =:= 64 ->
            decode_hex(HexB);
        undefined ->
            undefined
    end.

%% @doc Connect to the mesh when station seeds are configured. The macula
%% SDK auto-generates an ephemeral identity for empty opts (the proven path
%% the hecate-daemon uses); when a stable on-disk service keypair is
%% configured (`identity_key_path') we pass it so the service peers under a
%% consistent node id across restarts. Degrades to `no_client' (the
%% gen_server stays up) if seeds are unset or unreachable.
%%
%% NOTE: connection no longer depends on the realm-signed cert. The macula
%% `identity' opt wants a raw Ed25519 keypair, not a cert, and the mesh does
%% not yet verify realm membership at connect/publish — so requiring a cert
%% to connect was spurious (it kept every service dark). The cert is still
%% loaded + held (`service_cert/0') for the v2 swap-in, when the SDK enforces
%% realm-signed identity and this is where it gets passed.
attach_client(KeyPair) ->
    connect_seeds(configured_seeds(), KeyPair).

connect_seeds([], _KeyPair) ->
    undefined;
connect_seeds(Seeds, KeyPair) ->
    try macula:connect(Seeds, keypair_opts(KeyPair)) of
        {ok, Pool}    -> Pool;
        {error, _Why} -> undefined
    catch
        _:_ -> undefined
    end.

%% Load the stable on-disk service keypair (macula-native format, via
%% `macula_identity:save/2') when `identity_key_path' is configured;
%% `undefined' (the SDK auto-generates an ephemeral identity at
%% connect) only when `identity_key_path' itself is unconfigured. The
%% keypair is for peering AND for signing the service's own DHT
%% records — an ephemeral service peers and calls fine but cannot
%% advertise procedure records, so a service whose whole job is a
%% direct-dial RPC/Streaming *provider* silently never advertises
%% anything if this stays unset — confirmed live, not theoretical
%% (hecate-tube's `tube_mesh_providers' retried forever, `keypair/0'
%% never resolving, until this existed).
%%
%% Self-heals rather than requiring out-of-band provisioning: any load
%% failure (missing file — the common case, first boot — or a corrupt
%% one) generates a fresh keypair and persists it to the configured
%% path via `macula_identity:save/2', which `ensure_dir's the path
%% itself. Same pattern macula-realm's own mesh identity already
%% uses. Falls back to `undefined' only if the save itself fails
%% (e.g. a read-only filesystem).
load_keypair() ->
    keypair_from(application:get_env(hecate_om, identity_key_path)).

keypair_from({ok, Path}) ->
    loaded_or_generated(macula_identity:load(Path), Path);
keypair_from(undefined) ->
    undefined.

loaded_or_generated({ok, Kp}, _Path) ->
    Kp;
loaded_or_generated({error, _Reason}, Path) ->
    generate_and_save(Path).

%% Puzzle-hardened (mirrors macula-realm's own mesh identity, see
%% MaculaRealm.Mesh.mesh_identity/0): every station in this fleet
%% enforces S/Kademlia puzzle validation on CONNECT/HELLO. A plain
%% (non-puzzle) identity's handshake completes and then gets closed
%% with `puzzle_invalid' -> a graceful drain -> `drained', every
%% single connection, forever -- confirmed live: this is why
%% tube_mesh_providers could reach `advertised => true' (the local,
%% client-side bookkeeping) while no station's DHT-facing registry
%% ever actually held the advertisement, on a repeating ~96s
%% reject/reconnect cycle. Grinding difficulty 8 is sub-millisecond;
%% there's no reason to skip it.
generate_and_save(Path) ->
    KeyPair = macula_identity:generate(#{puzzle => true}),
    save_result(macula_identity:save(Path, KeyPair), KeyPair).

save_result(ok, KeyPair) -> KeyPair;
save_result({error, _Reason}, _KeyPair) -> undefined.

keypair_opts(undefined) -> #{};
keypair_opts(KeyPair)   -> #{identity => KeyPair}.

%% Org name from the `org' app env; `<<"_">>' when unset (records still
%% resolve, just under the placeholder org until one is configured).
load_org() ->
    case application:get_env(hecate_om, org) of
        {ok, O} when is_binary(O), O =/= <<>> -> O;
        _                                     -> <<"_">>
    end.

%% Station seeds, in precedence order:
%%   1. MACULA_STATION_SEEDS env var (comma-separated URLs) — lets each
%%      deployed instance dial a distinct station without rebuilding the
%%      image (e.g. one mpong-bot per beam node, one station each).
%%   2. `station_seeds' app env (sys.config default).
configured_seeds() ->
    case parse_seed_csv(os:getenv("MACULA_STATION_SEEDS")) of
        []    -> app_env_seeds();
        Seeds -> Seeds
    end.

app_env_seeds() ->
    case application:get_env(hecate_om, station_seeds) of
        {ok, Seeds} when is_list(Seeds) -> Seeds;
        _                                -> []
    end.

parse_seed_csv(false) -> [];
parse_seed_csv(Csv) ->
    [list_to_binary(Trimmed)
     || Part <- string:split(Csv, ",", all),
        Trimmed <- [string:trim(Part)],
        Trimmed =/= ""].

decode_hex(Hex) ->
    << <<(list_to_integer([A,B], 16))>> || <<A:8, B:8>> <= Hex >>.
