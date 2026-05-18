%%% @doc OTP application entry point for hecate-om.
%%%
%%% This is a library: the application boots the shared sup tree
%%% (health endpoint, capability publisher) so services can simply
%%% list `hecate_om` in their `applications` and call into the
%%% facade.
-module(hecate_om_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    hecate_om_sup:start_link().

stop(_State) ->
    ok.
