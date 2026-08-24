%%% @doc Tolerant field lookup on a decoded mesh payload map (RPC/stream
%%% `args', or a pubsub event payload), instead of every provider desk
%%% re-solving the same gotcha independently.
%%%
%%% macula's frame decoder round-trips a payload's keys through
%%% `binary_to_existing_atom/1' on the way in, so a caller that sent
%%% binary keys can find them waiting as atoms on the other side. Three
%%% incompatible ways of coping with this were already live in the
%%% workspace when this was written (see
%%% `hecate-om/plans/PLAN_HECATE_OM_MESH_WRAPPERS.md', piece F):
%%% `hecate-embedder' tries the atom form first, falling back to binary;
%%% `hecate-spartan' reimplements the same fallback (`mget/2,3') 11+
%%% times across its `federation_*' modules for pubsub payloads, not
%%% just RPC args; and `hecate-dns'/`-git'/`-llm'/`-rag''s `route/2'
%%% handlers pattern-match binary keys only, with zero tolerance —
%%% silently wrong if a real caller's payload ever arrives atom-keyed.
%%%
%%% `field/2,3' accepts either an atom or a binary key literal, whichever
%%% the caller naturally reaches for. Either way the atom form is tried
%%% first (the confirmed-live shape for both RPC/stream args and pubsub
%%% payloads, piece C/D's own live tests), the binary form second.
-module(hecate_om_wire).

-export([field/2, field/3]).

%% @equiv field(Key, Payload, undefined)
-spec field(atom() | binary(), map()) -> term().
field(Key, Payload) ->
    field(Key, Payload, undefined).

%% @doc Look up `Key' in `Payload', trying both the atom and binary form
%% of `Key' regardless of which one the caller passed in. Returns
%% `Default' if neither form is present.
-spec field(atom() | binary(), map(), term()) -> term().
field(Key, Payload, Default) when is_atom(Key) ->
    lookup(Key, atom_to_binary(Key, utf8), Payload, Default);
field(Key, Payload, Default) when is_binary(Key) ->
    lookup(existing_atom(Key), Key, Payload, Default).

lookup(AtomKey, BinKey, Payload, Default) ->
    case maps:find(AtomKey, Payload) of
        {ok, Value} -> Value;
        error -> maps:get(BinKey, Payload, Default)
    end.

%% `binary_to_existing_atom/2' raises for a binary with no atom form
%% anywhere in the VM yet. `Key' is a literal the calling handler wrote,
%% so its atom form almost always already exists -- but "almost always"
%% isn't a guarantee this module gets to lean on, so a miss here just
%% falls through to `undefined', same as any other absent key, rather
%% than crashing the handler over a decode-convenience lookup.
existing_atom(Bin) ->
    try binary_to_existing_atom(Bin, utf8) catch error:badarg -> undefined end.
