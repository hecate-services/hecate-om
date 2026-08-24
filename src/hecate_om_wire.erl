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
%%%
%%% `retryable/1' (piece G) is the response-side counterpart: whether a
%%% failed RPC/stream call outcome is worth retrying, per macula's own
%%% published BOLT#4 retry policy. `hecate-tom-player''s `tom_wire_
%%% macula.erl' was, before this, the one place in the workspace doing
%%% this at all -- asking `macula_bolt4:is_retryable/1' rather than
%%% keeping a second copy of its code table locally, which would rot
%%% the moment BOLT#4 grows a code.
-module(hecate_om_wire).

-export([field/2, field/3]).
-export([retryable/1]).

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

%% @doc Whether a failed RPC/stream call outcome is worth retrying.
%%
%% `{error, {call_error, Code, _Name}}' is macula's own documented
%% outcome shape for a CALL failure (`macula_station_link.erl''s own
%% doc table), not a caller-specific convention -- covers `macula:
%% call/5', `call_station/6,7,8', and `hecate_om_capabilities:
%% call_capability/5,7' uniformly. A success, or an error macula
%% didn't code-classify at all (a raw `catch', a timeout), has nothing
%% for the BOLT#4 table to say, so those are decided directly here
%% rather than delegated.
-spec retryable({ok, term()} | {error, term()} | {'EXIT', term()}) ->
    boolean().
retryable({ok, _Reply}) ->
    false;
retryable({error, {call_error, Code, _Name}}) ->
    bolt4_retryable(Code);
retryable({error, _Reason}) ->
    true;
retryable({'EXIT', _Reason}) ->
    true.

%% An unrecognized code raises INSIDE macula_bolt4:is_retryable/1
%% itself (an unknown-code lookup errors, it doesn't return `false') --
%% a real possibility across a protocol version skew, not defensive
%% paranoia. Treated as retryable rather than as a reason to abandon a
%% call outright over a code this build doesn't recognize yet.
bolt4_retryable(Code) ->
    try macula_bolt4:is_retryable(Code)
    catch _:_ -> true
    end.
