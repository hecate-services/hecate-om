%%% @doc Canonical barrel_docdb read-model wiring for hecate-services.
%%%
%%% Encapsulates "open (or create) a database at data_dir/read_model_id".
%%% Services don't call this module directly — `hecate_om:boot/1'
%%% dispatches here when the service module exports the optional
%%% `read_model_id/0' + `data_dir/0' callbacks from `hecate_om_service'.
%%%
%%% After boot, a service (its PRJ code, typically) reads/writes the read
%%% model with `barrel_docdb' directly, using the same `read_model_id/0'
%%% binary as the database name — barrel_docdb accepts the name or the pid
%%% interchangeably everywhere, so there is no separate handle to thread
%%% through. This mirrors `hecate_om_store', which likewise hands nothing
%%% back: the service already knows its own store_id/read_model_id.
-module(hecate_om_read_model).

-export([ensure/2]).

%% @doc Idempotent. Opens (creating on first boot) a barrel_docdb database
%% named `DbName' at `<DataDir>/<DbName>/'.
-spec ensure(binary(), file:filename_all()) -> ok | {error, term()}.
ensure(DbName, DataDir) when is_binary(DbName) ->
    SubDir = filename:join(DataDir, binary_to_list(DbName)),
    ok = filelib:ensure_path(SubDir),
    opened(barrel_docdb:create_db(DbName, #{data_dir => SubDir}), DbName, SubDir).

%% First boot: create_db opens it too (barrel keeps it open until closed or
%% the app stops). Later boots: the in-memory registry is empty again (the
%% prior process is gone), so create_db retries against the same on-disk
%% RocksDB directory and reopens it — that IS the "ensure" semantics, same
%% shape as reckon_db_sup:start_store's {already_started} short-circuit.
opened({ok, _Pid}, _DbName, _SubDir) ->
    ok;
opened({error, already_exists}, _DbName, _SubDir) ->
    ok;
opened({error, Reason}, DbName, SubDir) ->
    {error, {read_model_open_failed, DbName, SubDir, Reason}}.
