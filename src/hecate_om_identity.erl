%%% @doc Loads the service-principal cert at boot, hands out the
%%% cached macula client handle.
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
-module(hecate_om_identity).
-behaviour(gen_server).

-export([start_link/0, service_cert/0, macula_client/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    cert      :: binary() | undefined,
    client    :: term()  | undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

service_cert() ->
    gen_server:call(?MODULE, service_cert).

macula_client() ->
    gen_server:call(?MODULE, macula_client).

init([]) ->
    Cert = case load_cert() of
        {ok, C}    -> C;
        {error, _} -> undefined
    end,
    Client = case Cert of
        undefined -> undefined;
        _         -> attach_client(Cert)
    end,
    {ok, #state{cert = Cert, client = Client}}.

handle_call(service_cert, _From, #state{cert = undefined} = S) ->
    {reply, {error, no_cert}, S};
handle_call(service_cert, _From, #state{cert = C} = S) ->
    {reply, {ok, C}, S};
handle_call(macula_client, _From, #state{client = undefined} = S) ->
    {reply, {error, no_client}, S};
handle_call(macula_client, _From, #state{client = Cl} = S) ->
    {reply, {ok, Cl}, S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) -> {noreply, S}.
terminate(_Reason, _State) -> ok.

%%% Internals

load_cert() ->
    Path = application:get_env(hecate_om, service_cert_path,
                               "/etc/hecate/secrets/service-cert.pem"),
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        Err       -> Err
    end.

attach_client(_Cert) ->
    %% TODO: macula:connect(Url, #{cert => Cert}). For now return a
    %% placeholder so callers don't crash before SDK wiring lands.
    {placeholder_macula_client}.
