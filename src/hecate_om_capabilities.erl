%%% @doc Publishes a service's capability list onto the realm's
%%% capability-announce channel AND subscribes to that channel to
%%% track every other service's announcements.
%%%
%%% Two roles in one worker:
%%%
%%%   - Publisher: every `register/1` or `publish/0` call republishes
%%%     this service's capability summary onto `<<"_mesh.cap.announce">>'.
%%%   - Subscriber: at boot (and on every reconfigure), subscribes to
%%%     the same topic; inbound summaries land in `handle_info/2` and
%%%     update the `peer_caps' map.
%%%
%%% Other services / plugins call `lookup/1` with a capability name
%%% (`<<"hecate-rag.answer_query">>') and get back the list of
%%% services that advertised it. Caller uses that list to pick a
%%% target for `macula:call/5`.
-module(hecate_om_capabilities).
-behaviour(gen_server).

-export([start_link/0, register/1, publish/0, lookup/1, list/0, peers/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(ANNOUNCE_TOPIC, <<"_mesh.cap.announce">>).
-define(REBIND_INTERVAL_MS, 5_000).
-define(STALE_AFTER_MS,    120_000).  %% expire peer summaries older than 2 min

-record(state, {
    %% This service's own caps (set by register/1).
    capabilities = [] :: [hecate_om_service:capability()],

    %% service_name => summary_msg (last-seen announcement from that peer).
    peer_caps = #{} :: #{binary() => map()},

    %% Macula subscription handle.
    sub_ref = undefined :: reference() | undefined
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Caps) when is_list(Caps) ->
    gen_server:call(?MODULE, {register, Caps}).

publish() ->
    gen_server:call(?MODULE, publish).

%% @doc Find services that advertised the given capability name.
%% Returns `{ok, [#{service := Bin, capabilities := [...], published_at := Ms}]}'.
-spec lookup(binary()) -> {ok, [map()]}.
lookup(CapName) when is_binary(CapName) ->
    gen_server:call(?MODULE, {lookup, CapName}).

list() ->
    gen_server:call(?MODULE, list).

-spec peers() -> [map()].
peers() ->
    gen_server:call(?MODULE, peers).

%%% gen_server

init([]) ->
    self() ! try_subscribe,
    {ok, #state{}}.

handle_call({register, Caps}, _From, S) ->
    do_publish(Caps),
    {reply, ok, S#state{capabilities = Caps}};

handle_call(publish, _From, #state{capabilities = Caps} = S) ->
    do_publish(Caps),
    {reply, ok, S};

handle_call({lookup, CapName}, _From, #state{peer_caps = Peers} = S) ->
    NowMs = erlang:system_time(millisecond),
    Matches = lists:filter(
        fun(Summary) ->
            fresh(Summary, NowMs) andalso has_cap(Summary, CapName)
        end,
        maps:values(Peers)
    ),
    {reply, {ok, Matches}, S};

handle_call(list, _From, #state{capabilities = Caps} = S) ->
    {reply, Caps, S};

handle_call(peers, _From, #state{peer_caps = P} = S) ->
    {reply, maps:values(P), S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info(try_subscribe, #state{sub_ref = undefined} = S) ->
    case subscribe_announce() of
        {ok, Ref} ->
            logger:info("[hecate_om_capabilities] subscribed to ~s", [?ANNOUNCE_TOPIC]),
            {noreply, S#state{sub_ref = Ref}};
        {error, _Reason} ->
            erlang:send_after(?REBIND_INTERVAL_MS, self(), try_subscribe),
            {noreply, S}
    end;
handle_info(try_subscribe, S) ->
    {noreply, S};

handle_info({macula_event, _Ref, _Topic, #{service := ServiceName} = Summary},
            #state{peer_caps = Peers} = S) when is_binary(ServiceName) ->
    {noreply, S#state{peer_caps = Peers#{ServiceName => Summary}}};

handle_info(_Other, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%% Internals

do_publish(Caps) ->
    case {hecate_om_identity:macula_client(), hecate_om_identity:realm()} of
        {{ok, Pool}, {ok, Realm}} ->
            ServiceName = service_name_or_unknown(),
            Payload = summary_payload(ServiceName, Caps),
            try macula:publish(Pool, Realm, ?ANNOUNCE_TOPIC, Payload)
            catch _:_ -> ok
            end;
        _ ->
            %% No client / no realm yet — skip silently. register/1 +
            %% publish/0 will retry on the next caller-driven call.
            ok
    end.

subscribe_announce() ->
    case {hecate_om_identity:macula_client(), hecate_om_identity:realm()} of
        {{ok, Pool}, {ok, Realm}} ->
            try macula:subscribe(Pool, Realm, ?ANNOUNCE_TOPIC, self())
            catch C:R -> {error, {C, R}}
            end;
        _ ->
            {error, not_configured}
    end.

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

fresh(#{published_at := T}, NowMs) when is_integer(T) ->
    NowMs - T =< ?STALE_AFTER_MS;
fresh(_, _) ->
    false.

has_cap(#{capabilities := List}, CapName) when is_list(List), is_binary(CapName) ->
    lists:any(
        fun(#{name := Name}) when is_binary(Name) -> Name =:= CapName;
           (_) -> false
        end,
        List
    );
has_cap(_, _) ->
    false.
