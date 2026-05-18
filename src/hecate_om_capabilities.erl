%%% @doc Publishes a service's capability list onto the realm's
%%% capability-advertise channel.
%%%
%%% Other services and plugins discover capabilities by subscribing
%%% to `_mesh.cap.<service-name>` and aggregating the resulting
%%% per-station summaries.
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
    %% Auto-publish on register; consumers can call publish/0 again
    %% later for manual refresh.
    do_publish(Caps),
    {reply, ok, S#state{capabilities = Caps}};
handle_call(publish, _From, #state{capabilities = Caps} = S) ->
    do_publish(Caps),
    {reply, ok, S};
handle_call({lookup, _Name}, _From, S) ->
    %% TODO: query the bloom-advertised peer set + return matching peers.
    %% Needs macula:subscribe + accumulator.
    {reply, {ok, []}, S};
handle_call(list, _From, #state{capabilities = Caps} = S) ->
    {reply, Caps, S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) -> {noreply, S}.
terminate(_Reason, _State) -> ok.

%%% Internals

do_publish(Caps) ->
    case {hecate_om_identity:macula_client(), hecate_om_identity:realm()} of
        {{ok, Pool}, {ok, Realm}} ->
            ServiceName = service_name_or_unknown(),
            Topic   = topic_for(ServiceName),
            Payload = summary_payload(ServiceName, Caps),
            try macula:publish(Pool, Realm, Topic, Payload)
            catch _:_ -> ok
            end;
        _ ->
            %% No client or no realm yet — skip silently. publish/0
            %% will be called again on the next capability refresh.
            ok
    end.

topic_for(ServiceName) when is_binary(ServiceName) ->
    Prefix = application:get_env(hecate_om, capability_topic, <<"_mesh.cap.">>),
    <<Prefix/binary, ServiceName/binary>>.

summary_payload(ServiceName, Caps) ->
    #{
        type         => capability_summary,
        service      => ServiceName,
        capabilities => Caps,
        published_at => erlang:system_time(millisecond)
    }.

service_name_or_unknown() ->
    case hecate_om:service_module() of
        undefined -> <<"unknown">>;
        Mod ->
            try maps:get(name, Mod:info()) of
                Name when is_binary(Name) -> Name
            catch _:_ -> <<"unknown">>
            end
    end.
