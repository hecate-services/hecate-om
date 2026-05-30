%%% @doc Loads the service-principal cert at boot and a Macula SDK
%%% client handle. Held in a gen_server so every other process can
%%% borrow the pool through `hecate_om:macula_client/0`.
%%%
%%% Each hecate-service has its OWN realm-signed credential (NOT a
%%% user's). The credential lives at /etc/hecate/secrets/service-cert.pem
%%% inside the container; the host mounts the per-service directory
%%% from /etc/hecate/secrets/<service-name>/ onto that path.
%%%
%%% v1: long-lived realm-signed cert provisioned out-of-band by a
%%% realm-admin script. v2: short-lived UCAN auto-rotated from a
%%% realm HTTP endpoint. The v2 swap-in lands here without touching
%%% consumers.
%%%
%%% Connect-degradation: when seeds aren't reachable (early boot,
%%% test harness, no station nearby), `macula_client/0` returns
%%% `{error, no_client}` and consumers should fall back to no-op
%%% behaviour. The service stays up; it just doesn't talk to the mesh.
-module(hecate_om_identity).
-behaviour(gen_server).

-export([start_link/0, service_cert/0, macula_client/0, realm/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    cert      :: binary() | undefined,
    client    :: pid()    | undefined,
    realm     :: binary() | undefined   %% 32-byte realm tag
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

init([]) ->
    Cert  = case load_cert() of
        {ok, C}    -> C;
        {error, _} -> undefined
    end,
    Realm = load_realm(),
    %% Connect off the init path and retry. At boot hecate_om may start
    %% before the macula SDK app is fully up, so a single inline connect
    %% races it and loses (the bug that kept services dark even with seeds).
    %% handle_info(connect) attempts + reschedules until a pool attaches,
    %% and re-attaches if the pool later dies.
    self() ! connect,
    {ok, #state{cert = Cert, client = undefined, realm = Realm}}.

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

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(connect, #state{client = undefined} = S) ->
    case attach_client() of
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

%% @doc Realm tag = 32-byte binary. v1: read from env (operator
%% pins it via `hecate-gitops/system/<service>.env`). v2: extract
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
attach_client() ->
    case configured_seeds() of
        [] ->
            undefined;
        Seeds ->
            try macula:connect(Seeds, identity_opts()) of
                {ok, Pool}     -> Pool;
                {error, _Why}  -> undefined
            catch
                _:_ -> undefined
            end
    end.

%% Use a stable on-disk service keypair (macula-native format, via
%% `macula_identity:save/2') when one is configured + loadable; otherwise
%% let the SDK auto-generate an ephemeral identity. Either way the service
%% connects and can publish — the identity is for peering, not authorization.
identity_opts() ->
    case application:get_env(hecate_om, identity_key_path) of
        {ok, Path} ->
            case macula_identity:load(Path) of
                {ok, KeyPair} -> #{identity => KeyPair};
                {error, _}    -> #{}
            end;
        undefined ->
            #{}
    end.

configured_seeds() ->
    case application:get_env(hecate_om, station_seeds) of
        {ok, Seeds} when is_list(Seeds) -> Seeds;
        _                                -> []
    end.

decode_hex(Hex) ->
    << <<(list_to_integer([A,B], 16))>> || <<A:8, B:8>> <= Hex >>.
