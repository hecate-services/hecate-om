%%% @doc Cowboy handler — GET /health.
%%%
%%% Returns 200 + JSON when the service is `ok`; 503 + JSON for
%%% `{degraded, _}` or `{down, _}`. Podman's HEALTHCHECK and
%%% Kubernetes-style liveness probes consume this.
-module(hecate_om_health_handler).

-export([init/2, routes/0]).

routes() ->
    [{"/health", ?MODULE, []}].

init(Req0, State) ->
    case hecate_om:health() of
        ok ->
            Mod  = hecate_om:service_module(),
            Info = case Mod of
                undefined -> #{};
                _         -> Mod:info()
            end,
            Body = jsx:encode(Info#{status => <<"ok">>}),
            Req  = cowboy_req:reply(200,
                                    #{<<"content-type">> => <<"application/json">>},
                                    Body, Req0),
            {ok, Req, State};
        {degraded, Reason} ->
            reply_unhealthy(503, <<"degraded">>, Reason, Req0, State);
        {down, Reason} ->
            reply_unhealthy(503, <<"down">>, Reason, Req0, State)
    end.

reply_unhealthy(Code, Status, Reason, Req0, State) ->
    Body = jsx:encode(#{
        status => Status,
        reason => iolist_to_binary(io_lib:format("~p", [Reason]))
    }),
    Req = cowboy_req:reply(Code,
                           #{<<"content-type">> => <<"application/json">>},
                           Body, Req0),
    {ok, Req, State}.
