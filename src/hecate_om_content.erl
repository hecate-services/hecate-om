%%% @doc Put/get content on the mesh via macula's supervised
%%% `macula_feeder'/`macula_download', blocking with a timeout — what
%%% an HTTP handler actually wants (bytes or an MCID back), instead of
%%% a pid it has nothing to do with.
%%%
%%% Piece E, `PLAN_HECATE_OM_MESH_WRAPPERS.md'. Derived from
%%% `hecate-tube''s `tube_content_put.erl'/`tube_content_get.erl',
%%% which carry a hard-won, confirmed-live lesson this module exists
%%% specifically to not lose: `macula_download''s direct-dial path
%%% (`start_link_direct/4,5') only resolves content that has a
%%% `content_announcement' DHT record, and only *chunked* content gets
%%% one (`macula_download''s own moduledoc: "Only chunked content is
%%% discoverable this way"). A small blob — a logo, a thumbnail — never
%%% gets one, so direct-dial 404s even immediately after upload;
%%% confirmed live on beam02. This module always uses the *pooled*
%%% `start_link/4,5' for both put and get, never `start_link_direct',
%%% so put and get sides can never disagree about which path a given
%%% piece of content is reachable through.
%%%
%%% This is the public facade, named for the operation a caller wants
%%% (`put'/`get'). The actual `macula_feeder'/`macula_download'
%%% behaviour callbacks live in the tiny `hecate_om_content_feeder'/
%%% `hecate_om_content_downloader' modules — named for the SDK
%%% contract each satisfies rather than the operation, since neither
%%% carries any domain content of its own (that all lives here); see
%%% `hecate_om_content_feeder''s moduledoc for why they're separate
%%% files at all (both behaviours declare `init/1', and the compiler
%%% rejects declaring both on one module).
%%%
%%% `{error, mesh_unavailable}' when this service isn't attached to a
%%% pool or has no realm configured yet — same contract as
%%% `hecate_om:mesh_handles/0', `hecate_om_pubsub', and
%%% `hecate_om_capabilities'.
-module(hecate_om_content).

%% put/2 and get/1 would otherwise be ambiguous with the auto-imported
%% erlang:put/2 / erlang:get/1 process-dictionary BIFs -- the same
%% well-known clash every put/get-shaped module (dict, maps, ets...)
%% resolves this way.
-compile({no_auto_import, [put/2, get/1]}).

-export([put/1, put/2, get/1, get/2]).

%% Pure helper — realm resolution kept side-effect-free, same
%% convention as `hecate_om_pubsub.erl'.
-export([resolve_realm/2]).

-define(DEFAULT_TIMEOUT_MS, 15_000).
-define(RESULT_TAG, hecate_om_content_result).

-type content_opts() :: #{realm => binary(), timeout => pos_integer()}.

-export_type([content_opts/0]).

%% @doc Put `Bytes' into content storage using this service's own mesh
%% handle and realm. Blocks until the put resolves or `Opts''s
%% `timeout' (default 15000ms) elapses.
-spec put(binary()) -> {ok, macula:mcid()} | {error, term()}.
put(Bytes) ->
    put(Bytes, #{}).

%% @doc As `put/1', with `Opts':
%%   `realm'   — put on a realm other than this service's own (same
%%               dual-realm need as pieces B/C — a fleet realm for
%%               hecate_om's own plumbing, a separate business/public
%%               realm for the content itself).
%%   `timeout' — milliseconds to wait for the outcome before
%%               cancelling the transfer and returning
%%               `{error, timeout}'. Default 15000.
-spec put(binary(), content_opts()) -> {ok, macula:mcid()} | {error, term()}.
put(Bytes, Opts) when is_binary(Bytes), is_map(Opts) ->
    do_put(hecate_om:mesh_handles(), Bytes, Opts).

do_put({ok, Pool, DefaultRealm}, Bytes, Opts) ->
    Realm   = resolve_realm(Opts, DefaultRealm),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT_MS),
    Ref     = make_ref(),
    reply_or_cancel(
      macula_feeder:start_link(hecate_om_content_feeder, Pool, Realm, Bytes,
                               {self(), Ref}),
      fun macula_feeder:cancel/1, Ref, Timeout);
do_put({error, mesh_unavailable} = Err, _Bytes, _Opts) ->
    Err.

%% @doc Get the bytes for `Mcid' using this service's own mesh handle
%% and realm. Blocks until the get resolves or `Opts''s `timeout'
%% (default 15000ms) elapses.
-spec get(macula:mcid()) -> {ok, binary()} | {error, term()}.
get(Mcid) ->
    get(Mcid, #{}).

%% @doc As `get/1', with the same `Opts' as `put/2'.
-spec get(macula:mcid(), content_opts()) -> {ok, binary()} | {error, term()}.
get(Mcid, Opts) when is_binary(Mcid), is_map(Opts) ->
    do_get(hecate_om:mesh_handles(), Mcid, Opts).

do_get({ok, Pool, DefaultRealm}, Mcid, Opts) ->
    Realm   = resolve_realm(Opts, DefaultRealm),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT_MS),
    Ref     = make_ref(),
    reply_or_cancel(
      macula_download:start_link(hecate_om_content_downloader, Pool, Realm,
                                 Mcid, {self(), Ref}),
      fun macula_download:cancel/1, Ref, Timeout);
do_get({error, mesh_unavailable} = Err, _Mcid, _Opts) ->
    Err.

%% @doc The realm a put/get actually uses: `Opts''s `realm' override
%% when given, otherwise this service's own default realm.
-spec resolve_realm(content_opts(), binary()) -> binary().
resolve_realm(Opts, DefaultRealm) ->
    maps:get(realm, Opts, DefaultRealm).

%% Real cancel, not just giving up locally — a timed-out transfer
%% still holds an open QUIC stream on the other end until told
%% otherwise (see macula_feeder/macula_download's own moduledoc,
%% "Real cancel, real underneath"); hecate-tube's own wrappers already
%% learned to do this.
reply_or_cancel({ok, Pid}, CancelFun, Ref, Timeout) ->
    receive
        {?RESULT_TAG, Ref, Result} -> Result
    after Timeout ->
        catch CancelFun(Pid),
        {error, timeout}
    end;
reply_or_cancel({error, _Reason} = Err, _CancelFun, _Ref, _Timeout) ->
    Err.
