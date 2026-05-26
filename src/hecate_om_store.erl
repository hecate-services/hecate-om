%%% @doc Canonical reckon-db + evoq wiring helper for hecate-services.
%%%
%%% Encapsulates the "start a store, wait for it, start the
%%% per-store evoq subscription" pattern documented as MANDATORY in
%%% `hecate-social/hecate-corpus/skills/ANTIPATTERNS_EVENT_SOURCING.md`.
%%%
%%% Services don't call this module directly — `hecate_om:boot/1`
%%% dispatches here when the service module exports the optional
%%% `store_id/0` + `data_dir/0` callbacks from `hecate_om_service`.
%%%
%%% The sys.config for any service that uses this helper MUST also
%%% set evoq's adapter to reckon_evoq_adapter:
%%%
%%%   {evoq, [
%%%       {event_store_adapter, reckon_evoq_adapter},
%%%       {subscription_adapter, reckon_evoq_adapter},
%%%       {store_id, my_service_store},   %% fallback for dispatch
%%%       {consistency, eventual}
%%%   ]}
%%%
%%% Without that block, evoq crashes on first dispatch with
%%% `{not_configured, event_store_adapter}'. hecate_om can't inject
%%% it at runtime because evoq starts as a release-boot application
%%% before any service's start/2 runs.
-module(hecate_om_store).

-include_lib("reckon_db/include/reckon_db.hrl").

-export([ensure/2,
         ensure_store/2,
         ensure_subscription/1,
         wait_for_store/2]).

-define(DEFAULT_TIMEOUT_MS, 30_000).

%% @doc One-call wiring: ensure the store + the subscription. Called
%% by hecate_om:boot/1 when the service module declares store_id/0
%% and data_dir/0.
-spec ensure(atom(), file:filename_all()) -> ok | {error, term()}.
ensure(StoreId, DataDir) when is_atom(StoreId) ->
    case ensure_store(StoreId, DataDir) of
        ok           -> ensure_subscription(StoreId);
        {error, _}=E -> E
    end.

%% @doc Idempotent. Starts a `single`-mode reckon_db_store at
%% `<DataDir>/<StoreId>/` and waits for it to register.
-spec ensure_store(atom(), file:filename_all()) -> ok | {error, term()}.
ensure_store(StoreId, DataDir) when is_atom(StoreId) ->
    SubDir = filename:join(DataDir, atom_to_list(StoreId)),
    ok = filelib:ensure_path(SubDir),
    Config = #store_config{
        store_id          = StoreId,
        data_dir          = SubDir,
        mode              = single,
        writer_pool_size  = 5,
        reader_pool_size  = 5,
        gateway_pool_size = 1,
        options           = #{}
    },
    case reckon_db_sup:start_store(Config) of
        {ok, _Pid}                       -> wait_for_store(StoreId, ?DEFAULT_TIMEOUT_MS);
        {error, {already_started, _Pid}} -> ok;
        {error, Reason}                  -> {error, {start_store_failed, Reason}}
    end.

%% @doc Block until the store is registered with reckon_db, or the
%% deadline passes.
-spec wait_for_store(atom(), pos_integer()) -> ok | {error, term()}.
wait_for_store(StoreId, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(StoreId, Deadline).

wait_loop(StoreId, Deadline) ->
    case lists:member(StoreId, safe_which_stores()) of
        true  -> ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true  -> {error, {store_not_ready, StoreId}};
                false ->
                    timer:sleep(100),
                    wait_loop(StoreId, Deadline)
            end
    end.

safe_which_stores() ->
    try reckon_db_sup:which_stores()
    catch _:_ -> []
    end.

%% @doc Start the per-store evoq subscription. Idempotent.
-spec ensure_subscription(atom()) -> ok | {error, term()}.
ensure_subscription(StoreId) when is_atom(StoreId) ->
    case evoq_store_subscription:start_link(StoreId) of
        {ok, _Pid}                       -> ok;
        {error, {already_started, _Pid}} -> ok;
        {error, Reason}                  -> {error, {start_subscription_failed, Reason}}
    end.
