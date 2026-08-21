# Plan: Survey — Integrating the Top-Level Macula API into hecate-om

**Status:** Handover — survey not started
**Created:** 2026-08-21
**Last Updated:** 2026-08-21

## Overview

Deep exploration, deferred to next session: survey how the top-level
macula SDK API can best be integrated into `hecate-om`, in the most
developer-friendly manner possible for a `hecate-services/hecate-X`
service author. This document is the handover — it records what's
already known so the next session doesn't have to re-derive it, and
lays out the open questions to actually work through. No design
decision has been made yet.

---

## Why this, why now

This follows directly from a `macula-io/macula` documentation session
(2026-08-21) that spent its whole arc on exactly this question one layer
down: the SDK's own guides used to lead with raw wire primitives
(`macula:subscribe/4,5`, `macula:call/5`, `macula:publish/4,5`, ...) when
"devs will use the high-level stuff." That session split every guide into
a daemon-facing **Guide** (supervised OTP-behaviour wrappers only —
`macula_subscriber`/`macula_publisher`, `macula_request`/`macula_response`,
`macula_feeder`/`macula_download`, `macula_pusher`/`macula_upload`,
`macula_streamer`/`macula_stream_sink`) and a library-facing **Protocol**
doc (the raw primitives underneath, for anyone building something the
wrapper doesn't fit). See `macula-io/macula`'s `docs/guides/{rpc,pubsub,
content,streaming}/` and `CHANGELOG.md` 9.13.4–9.13.6 for the full story.

`hecate-om` is a real instance of exactly that same question, one layer
further up: it's the substrate every hecate-service daemon stands on, and
right now it exposes almost none of macula's supervised-wrapper layer to
its own consumers — see below. The vocabulary and the split
(supervised/daemon-friendly vs. raw/library-friendly) from the SDK session
transfers directly and is worth reusing rather than reinventing.

---

## What's already known (verified 2026-08-21, don't re-derive)

### hecate-om's current macula surface is thin and RPC-only

`src/hecate_om.erl` (the public facade) exposes exactly:

```erlang
boot/1, boot/2, advertise_capabilities/0, call_capability/4,
health/0, service_cert/0, macula_client/0, service_module/0
```

Of these, only two touch macula directly:

- **`macula_client/0`** → `hecate_om_identity:macula_client/0` → `{ok, Pool}`
  or `{error, no_client}`. This is the ONLY way to reach the raw SDK pool.
  `Pool` is typed as opaque `term()` in the spec — a service using it has
  to already know the raw macula API to do anything with it.
- **`call_capability/4`** → `hecate_om_capabilities:call_capability/5,7`.
  This is a hand-rolled RPC direct-dial: resolve providers from
  `procedure_advertisement` DHT records itself, resolve a serving
  station, dial and call, fail over to the next provider on error. It
  does **not** use `macula_request:start_link_direct/6,7,8` (the SDK's
  own supervised direct-dial wrapper, which does the same resolve+dial
  sequence) — it re-implements the resolve/dial/failover logic locally in
  `hecate_om_capabilities.erl`. Worth checking during the survey whether
  that predates the SDK wrapper existing, or was a deliberate choice, and
  whether consolidating onto the SDK wrapper is now viable.

**PubSub, Content, and Streaming have zero wrapping at the hecate-om
level.** No `hecate_om:subscribe`, no `hecate_om:publish`, no content
put/get, no streaming. A service wanting any of those has to call
`hecate_om:macula_client()`, unwrap the pool itself, separately fetch the
realm (`hecate_om_identity:realm/0` — **not even re-exported through the
public `hecate_om` facade**, only reachable by calling the identity
gen_server module directly), and then either call raw `macula:*` or reach
for the SDK's supervised wrappers (`macula_subscriber`, `macula_feeder`,
etc.) entirely on their own.

### The pool model: one pool per service, already lifecycle-managed

`src/hecate_om_identity.erl` is a `gen_server` that:

- Connects once at boot (`macula:connect/2`), off the `init/1` path via
  `self() ! connect` + retry every 5s, specifically to avoid racing the
  macula SDK application's own startup.
- Re-attaches automatically on pool death (`erlang:monitor(process, Pool)`
  + a `'DOWN'` handler that reschedules `connect`).
  Degrades to `{error, no_client}` (service stays up, mesh calls no-op)
  when seeds are unset or unreachable — never crashes the service for a
  missing mesh.
- Holds one `Pool`, one `realm` (32-byte tag, from app env or
  `MACULA_STATION_SEEDS`-adjacent config), one optional stable `keypair`
  (for signing DHT records — an ephemeral-identity service can peer and
  call but not advertise), one `org` name.

This means: **any new pubsub/content/streaming wrapping has a single,
already-managed `{Pool, Realm}` pair to build on** — it does not need its
own connection/reconnection logic. That's the same shape
`hecate_om_capabilities` already leans on for RPC.

### The service behaviour contract has an extension precedent to reuse

`src/hecate_om_service.erl` defines `hecate_om_service` — 6 required
callbacks (`info/0`, `start/1`, `stop/1`, `health/0`, `capabilities/0`,
`identity_spec/0`) plus 5 **optional** callbacks
(`store_id/0`, `data_dir/0`, `store_indexes/0`, `store_mode/0`,
`store_integrity/0`) that `hecate_om:boot/1` detects via
`erlang:function_exported/3` and wires up automatically *before* calling
the service's own `start/1` — but only for services that opt in by
exporting them. A "producer-only" service that omits them pays nothing.

This optional-callback pattern is the existing, working precedent for
"declare what you need, hecate_om wires it for you at boot" — e.g. a
future `subscriptions/0` callback (topic → handler mapping) that
`hecate_om:boot/1` turns into `macula_subscriber:start_link/6` calls
under a supervisor it owns, the same way `store_id/0`+`data_dir/0` turn
into a `reckon_db_sup:start_store/1` call today. Worth evaluating as a
candidate shape rather than starting from nothing.

### The stated non-goal to reconcile with

`README.md`'s own "What this library is (and isn't)" section says
explicitly:

> It is not: ... A network library. Services talk to `macula-station` via
> the macula SDK like any other Macula client: **outbound only**.

Any integration design has to reconcile with this. It probably does NOT
mean "wrap nothing" (the capability layer already wraps RPC), but it does
mean the bar for adding NEW macula-facing surface to hecate-om should be
"removes real, repeated friction for every service" rather than "makes
hecate-om a general-purpose mesh-messaging framework." Worth revisiting
this exact sentence with the maintainer before committing to a direction
— it may need updating regardless of what's decided, since a
`call_capability`-shaped precedent already exists.

### The gap is not theoretical — services are already reinventing it

Real `hecate-services/hecate-X` repos already call raw
`macula:subscribe`/`macula:publish`/etc. directly, each in its own
hand-rolled module, because hecate-om gives them nothing to build on:

- `hecate-mpong-bot/src/hecate_mesh.erl`
- `hecate-tom-ocean/src/tom_ocean_mesh.erl`
- `hecate-tom-player/src/tom_wire_macula.erl`
- `hecate-tom-world/src/join_the_mesh/tom_crier.erl`

These four are worth reading first — they're the closest thing to a
requirements document this survey has: real services independently
solving "how do I do pub/sub from a hecate-om service" without any
help from hecate-om, and each one is a candidate data point for what a
shared wrapper should actually look like (or a warning sign about a
pattern nobody should have had to write four times).

### Current versions (as of this handover)

- `hecate-om` is at **v0.14.0**, `rebar.config` pins `{macula, "~> 9.0"}`
  (bumped in the last commit, `752a568`, specifically to pull in
  direct-dial across all four SDK primitive pairs).
- `macula-io/macula` is at **9.13.8** (published to hex.pm the same day
  this handover was written), with the Guide/Protocol split fully live —
  read `docs/guides/{rpc,pubsub,content,streaming}/*_GUIDE.md` fresh
  before starting the survey; don't rely on memory of the pre-split shape.

---

## Open questions for the survey (genuinely open — not pre-answered)

1. **Which primitive pairs actually warrant hecate-om-level wrapping?**
   RPC already has one (`call_capability`, DHT-discovery-based). Do
   PubSub, Content, and Streaming each need an equivalent, or only some?
   Read the four DIY modules above before guessing.
2. **Declarative (behaviour callback) vs. imperative (facade function)?**
   The `store_id/0`/`data_dir/0` precedent is declarative — a service
   states what it needs, hecate_om wires it at boot. `call_capability/4`
   is imperative — the service calls it whenever it wants. PubSub
   subscriptions feel like they'd want the declarative shape (a service
   knows its topics at compile time); publishing feels more like it wants
   the imperative shape (published on demand, from wherever). Does that
   intuition hold once real services are checked against it?
3. **Should `call_capability`'s hand-rolled resolve/dial/failover be
   consolidated onto `macula_request:start_link_direct/6,7,8`?** Separate
   from the PubSub/Content/Streaming question, but touches the same
   surface and the same file. Check why it wasn't built on the SDK
   wrapper in the first place (git blame / CHANGELOG) before assuming
   it's just tech debt.
4. **Does the realm need its own public facade export?**
   `hecate_om_identity:realm/0` exists but isn't re-exported through
   `hecate_om`. Any new wrapper needs both `Pool` and `Realm` together —
   worth deciding whether to expose `realm/0` on the facade directly, or
   keep it bundled inside whatever new wrapper functions get added (so a
   service never needs the realm by itself).
5. **What does "most developer-friendly" concretely mean here?**
   Fewest lines to subscribe to a topic and get events into a
   `gen_server`? Fewest new concepts a service author has to learn beyond
   `hecate_om_service`'s existing callback shape? Consistency with how
   `macula_subscriber`/`macula_feeder`/etc. already work at the SDK level
   (so a developer who's read the SDK's own Guides feels at home)?
   Pick a concrete definition before designing against it, not after.
6. **Where does this live?** New callbacks on `hecate_om_service`? A new
   `hecate_om_pubsub`/`hecate_om_content`/`hecate_om_streaming` module
   family, mirroring `hecate_om_capabilities`? Something that composes
   with `hecate_om:boot/1` the way store-wiring does? Not obvious yet —
   depends on the answers above.

---

## Where to start next session

1. Re-read `macula-io/macula`'s current `docs/guides/pubsub/PUBSUB_GUIDE.md`,
   `content/CONTENT_GUIDE.md`, `streaming/STREAMING_GUIDE.md` fresh (9.13.8
   shape) — the supervised-wrapper sections specifically, since those are
   what any hecate-om integration would be building on top of, not the
   raw Protocol docs.
2. Read the four DIY modules listed above in full — they're the closest
   thing to real requirements this survey has.
3. Read `hecate_om_capabilities.erl` in full (not just the excerpt in
   this handover) as the one existing precedent for "how hecate-om has
   already chosen to wrap a macula primitive."
4. From there: answer the open questions above, then decide whether this
   becomes a new PLAN (implementation) or gets folded into an existing
   one.
