# How to build a mesh-fact-driven read model with hecate-om

A "read-model service" is one whose whole job is: listen for mesh facts of a given kind,
maintain a queryable local copy, and serve it back out (usually via a `capabilities/0`
RPC). `hecate-services/hecate-stations` is the running example this guide is built from —
station directory-by-geo. A capability directory would be the same shape, subscribing to
`procedure_advertisement` facts instead of `node_record` ones.

This assumes you already have a booting service — see
[`service_anatomy.md`](service_anatomy.md) first if not — and already know how to
subscribe to a mesh topic — see [`mesh_native_services.md`](mesh_native_services.md)'s
chapter 3 first if not. This guide is specifically about the part that goes wrong if you
stop at "subscribe, then write": **staleness and scale**. The pattern is documented in
full, with the real bug that motivated it, in the corpus —
[`hecate-corpus/examples/MESH_FACT_READ_MODELS.md`](https://github.com/hecate-social/hecate-corpus/blob/main/examples/MESH_FACT_READ_MODELS.md).
Read that for the "why." This is the "how, with this library's actual functions."

## The shape: three modules, not two

A read-model service that goes straight from a `subscriptions/0` handler to a database
write has nowhere to put the "should this actually be written" decision — which is
exactly the bug `hecate-stations` shipped with. Split it into three:

```
subscriptions/0 (Listener)  →  a Policy module (pure function)  →  a Projection module (the store)
```

### 1. Listener — verify, then hand off, nothing else

```erlang
%% my_x_service.erl
subscriptions() ->
    [{<<"_dht.records.6.stored">>, ingest_capability_listener, []}].
```

```erlang
%% ingest_capability_listener.erl
-module(ingest_capability_listener).
-behaviour(macula_subscriber).
-export([init/1, handle_event/4]).

init(Args) -> {ok, Args}.

handle_event(_Topic, Record, _Meta, State) ->
    case macula_record:verify(Record) of
        {ok, Verified} -> on_capability_fact_maybe_admit:handle(Verified);
        {error, _}     -> ok
    end,
    {noreply, State}.
```

`hecate_om:boot/1` wires this from your `subscriptions/0` callback automatically —
supervised, reconnect-surviving, no code of your own needed for either. See
`mesh_native_services.md` chapter 3 if this part is new to you.

### 2. Policy — the admit / supersede / expire decision, and only that decision

```erlang
%% on_capability_fact_maybe_admit.erl
-module(on_capability_fact_maybe_admit).
-export([handle/1, decide/2]).

handle(Record) ->
    Fields    = macula_record:read_procedure_advertisement(Record),
    ExpiresAt = macula_record:expires_at(Record),
    Key       = maps:get(procedure_uri, Fields),
    Existing  = capability_read_model:find(Key),
    case decide(Existing, ExpiresAt) of
        admit -> capability_read_model:upsert(Fields, ExpiresAt);
        stale -> ok
    end.

-spec decide(map() | undefined, integer()) -> admit | stale.
decide(undefined, _IncomingExpiresAt) -> admit;
decide(#{<<"expires_at">> := Cur}, Incoming) when Incoming >= Cur -> admit;
decide(_Existing, _Incoming) -> stale.
```

Keep `decide/2` a pure function — no mesh call inside it. This is the library's own
existing testing convention (`mesh_native_services.md`'s "Testing your service's mesh
code" section: *"If your handler has any decision logic... export it and test it
directly — no mesh at all"*), just applied to the one decision this pattern needs that
none of the existing wrapper modules make for you.

```erlang
%% test/on_capability_fact_maybe_admit_tests.erl
-include_lib("eunit/include/eunit.hrl").

admits_a_never_seen_key_test() ->
    ?assertEqual(admit, on_capability_fact_maybe_admit:decide(undefined, 12345)).

admits_a_fresher_republish_test() ->
    ?assertEqual(admit, on_capability_fact_maybe_admit:decide(
        #{<<"expires_at">> => 100}, 200)).

drops_a_late_stale_delivery_test() ->
    ?assertEqual(stale, on_capability_fact_maybe_admit:decide(
        #{<<"expires_at">> => 200}, 100)).
```

Zero mesh, zero station, runs in the default `rebar3 eunit` gate — no `test_live/`
needed for this part.

### 3. Projection — dumb write, expiry-aware read

```erlang
%% capability_read_model.erl
upsert(Fields, ExpiresAt) ->
    Doc = existing_or_new(storage_key(Fields)),
    put(Doc#{<<"expires_at">> => ExpiresAt, ...}).

fold(Fun, Acc) ->
    Now = erlang:system_time(millisecond),
    fold_docs(fun(Doc, A) ->
        case maps:get(<<"expires_at">>, Doc, 0) > Now of
            true  -> Fun(Doc, A);
            false -> {ok, A}   %% expired -- never surface as live
        end
    end, Acc).
```

The read-time filter is what makes this correct with zero background maintenance — an
entity that died stops being served the instant its mirrored `expires_at` passes, with no
dependency on ever receiving an explicit tombstone (which, for a crash or a power loss,
never arrives). A periodic purge that deletes long-expired docs is worth adding once
storage growth matters, but it is a size optimization, not a correctness requirement —
don't let "we haven't built the sweep yet" block shipping the read-time filter, which is
the part that actually fixes staleness.

## Two things this gets you for free once you have it

**Discovery that scales past a crawl.** A one-time `find_records_by_type` call only sees
what one relay locally holds — fine at ten entities, silently incomplete at thousands (see
the corpus doc for the specific code comment this is drawn from). The subscription in step
1, left running, doesn't have that ceiling: every live entity's own periodic republish
(required to keep its own fact from expiring) is a fresh delivery to every subscriber,
mesh-wide. If you use `find_records_by_type` at all, treat it as a warm-start for faster
initial convergence, never as what completeness depends on.

**Staleness handling for free, from the same mechanism.** The entity that republishes to
stay alive in the DHT is the same republish your Listener hears and your Policy re-admits.
Stop republishing (because you died) and both effects happen together: the DHT record
ages out on its own schedule, and this service's mirrored copy ages out on the same
schedule, because it's the same `expires_at`.

## The one thing to get right that this library doesn't default correctly today

**If you're serving a capability via `capabilities/0`, check what TTL your own
advertisement uses.** `hecate_om_capabilities` re-advertises every 30 seconds
(`macula_response:advertise_direct/7`, re-invoked on a timer) but does not pass
`ttl_ms` — so the underlying `procedure_advertisement` record falls back to the generic
envelope default, currently 48 hours. That means a service that dies still has a
*discoverable, callable-looking* capability advertisement sitting in the DHT for up to two
days, no matter how often a live instance would have refreshed it. The 30s cadence buys
freshness for callers of a live service; it does nothing for how fast a dead one's entry
disappears, because nothing shortened the TTL to match the cadence.

If you're calling `advertise_direct` yourself (directly, or via a future `hecate_om`
change to `hecate_om_capabilities`), pass an explicit `ttl_ms` proportioned to your actual
republish interval — something like 3–4× the interval, matching the margin
`macula_station_announcer` already uses for stations (refreshing at 75% of TTL leaves the
same kind of buffer). Don't rely on the envelope default; it was sized for entities that
refresh on the order of hours, not seconds.

## Where to look next

- [`hecate-corpus/examples/MESH_FACT_READ_MODELS.md`](https://github.com/hecate-social/hecate-corpus/blob/main/examples/MESH_FACT_READ_MODELS.md) — the pattern, the "why," and the real bug it's drawn from
- [`mesh_native_services.md`](mesh_native_services.md) — subscribing/publishing/calling over the mesh, the layer this guide builds on
- [`service_anatomy.md`](service_anatomy.md) — the boot lifecycle this guide assumes
- `hecate-services/hecate-stations` — the real, currently-shipping example this whole
  guide was extracted from finding a genuine gap in, not a clean-room design
