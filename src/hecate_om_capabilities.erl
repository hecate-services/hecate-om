%%% @doc Publishes a service's capability list onto the mesh's
%%% bloom-advertise channel.
%%%
%%% Other services / plugins finding capabilities call
%%% `hecate_om_capabilities:lookup/1`. v1 walks the per-station
%%% peer_blooms; v2 caches at the SDK layer.
-module(hecate_om_capabilities).
-behaviour(gen_server).

-export([start_link/0, register/1, publish/0, lookup/1, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    capabilities = [] :: [hecate_om_service:capability()]
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Caps) when is_list(Caps) ->
    gen_server:call(?MODULE, {register, Caps}).

publish() ->
    gen_server:call(?MODULE, publish).

lookup(CapName) when is_binary(CapName) ->
    gen_server:call(?MODULE, {lookup, CapName}).

list() ->
    gen_server:call(?MODULE, list).

init([]) ->
    {ok, #state{}}.

handle_call({register, Caps}, _From, S) ->
    {reply, ok, S#state{capabilities = Caps}};
handle_call(publish, _From, #state{capabilities = Caps} = S) ->
    do_publish(Caps),
    {reply, ok, S};
handle_call({lookup, _Name}, _From, S) ->
    %% TODO: query the bloom-advertised peer set + return matching peers.
    {reply, {ok, []}, S};
handle_call(list, _From, #state{capabilities = Caps} = S) ->
    {reply, Caps, S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) -> {noreply, S}.
terminate(_Reason, _State) -> ok.

%%% Internals

do_publish(_Caps) ->
    %% TODO: hecate_om_identity:macula_client/0 →
    %% macula:publish(Client, ?_mesh.cap.<service>, summary_payload).
    ok.
