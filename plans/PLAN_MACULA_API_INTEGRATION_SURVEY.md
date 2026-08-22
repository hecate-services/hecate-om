# Plan: Survey — Integrating the Top-Level Macula API into hecate-om

**Status:** Survey complete — design recommendation ready for review (not yet approved, no code written).
**Superseded as the active thread by `hecate-services/hecate-tube/plans/PLAN_HECATE_TUBE_ROOT.md`** —
this survey's recommended design is deliberately not being implemented yet;
hecate-tube is being built first, against raw macula SDK primitives, as the
one complete real exemplar this design should be derived from. See that doc
for current status.
**Created:** 2026-08-21
**Last Updated:** 2026-08-22

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

## Survey findings (2026-08-21)

### New finding, more important than anything in the original handover: RPC is only HALF wrapped

`hecate_om_capabilities.erl` (read in full) does exactly two things on the
provider side: `register/1` and `publish/0`, both of which write signed
`procedure_advertisement` **DHT discovery records** via
`macula:put_record/2`. Grepping `src/` confirms it: there is **no call to
`macula:advertise/5` or `macula_response:advertise/5,6` anywhere in
hecate-om**. Line 69's own comment gives it away —
`Realm'), matching how a provider serves it via `macula:advertise'.` — a
plain admission that the actual "become callable, run the handler"
half happens *somewhere else*, outside hecate-om.

So today, a service that implements `capabilities()` and does nothing
else is **discoverable but not callable**: `hecate_om:boot/1` advertises
"ask me for `CapName`" into the DHT, but no handler is ever wired to
answer. `tom_ocean_mesh.erl` (one of the four DIY modules) confirms this
is a real, hit problem, not a theoretical one — it hand-rolls
`macula:advertise/5` for 3 procedures itself, duplicating the procedure
naming hecate_om_capabilities already computes privately
(`procedure_uri/3`, not exported) and re-deriving `{Pool, Realm}` to do
it.

This reframes open question 1: RPC isn't "already wrapped, do the other
three need the same." Its *provider* half has the exact same gap as
PubSub/Content/Streaming; only its *consumer* half (`call_capability`)
is actually done.

### Question 3 — settled, with a timeline

Git log + macula's CHANGELOG give a clean, factual answer:
`hecate_om_capabilities`'s hand-rolled resolve→verify→dial→failover
(commit `170fad6`, **2026-08-19**, "Slice 5") was written **one day
before** macula 9.5.0 shipped `macula_request:start_link_direct/6,7,8`
(**2026-08-20**, per `CHANGELOG.md`). It isn't tech debt from ignoring an
existing SDK wrapper — the wrapper didn't exist yet.

More importantly, it's not a like-for-like swap even now:
`call_capability` is **synchronous** and fails over across **every**
resolved provider on error; `RPC_GUIDE.md` describes
`start_link_direct` as **async/callback-based**
(`start_link` returns a pid, outcome lands later at `handle_reply/2`)
and resolves+dials **one** advertisement with no built-in multi-provider
failover of its own. Consolidating would mean either losing the
failover behavior, or re-implementing a failover loop around the async
wrapper — at which point most of the complexity being "removed" comes
back, in exchange for `rpc.*_v1` mesh-fact observability and a
supervisor-visible, cancellable pid. **Recommendation: don't
consolidate.** Revisit only if something concretely needs the
mesh-fact/cancellation behavior badly enough to justify rebuilding
failover on top of it.

### Question 4 — settled, and sharper than "export realm/0"

Confirmed real, not hypothetical: of the four DIY modules, **three**
(`hecate_mesh`, `tom_ocean_mesh`, `tom_wire_macula`) bypass the
`hecate_om` facade and call `hecate_om_identity:realm()` directly,
because there's no other way to get it. But the actual repeated
boilerplate is bigger than the bare realm — every one of the four
re-derives the same pairing-and-degrade shape:
`case {macula_client(), realm()} of {{ok,P},{ok,R}} -> ...; _ ->
{error, mesh_unavailable} end`. `tom_crier.erl` even re-fetches the pair
on *every single call* rather than caching it once.

**Recommendation:** export `hecate_om:mesh_handles/0 -> {ok, Pool,
Realm} | {error, mesh_unavailable}` on the facade, rather than (or
alongside) a bare `realm/0`. That's the thing all four modules actually
wanted, and it becomes the one shared foundation every new wrapper
(publish, subscribe, provider-side advertise) builds on — mirroring how
`hecate_om_capabilities` already centralizes this pairing for RPC.

### Question 1 + 2 — which primitives, declarative vs. imperative

The SDK-guides fork and the DIY-modules fork converge on the same split,
and it's cleaner than "per primitive pair": **it splits by which side
initiates.**

| Half | Shape that fits | Why |
|---|---|---|
| PubSub *subscribe* | **Declarative**, boot-wired | Topics are known at boot; 3/4 DIY services hand-rolled a version of this; SDK's `macula_subscriber` is a standing process per `(Realm,Topic)` — same shape as `store_id/0`. Caveat (SDK guide, explicit): pool restart does **not** auto-reattach subscribers — a boot-wired design must re-subscribe on `hecate_om_identity`'s reconnect, not just start once. `tom_ocean_mesh` hand-rolled exactly this reconcile-on-timer behavior. |
| PubSub *publish* | **Imperative**, facade call | Runtime-decided, fire-and-forget. All 4 DIY services want it off their own process but never wanted it declared at boot; 2 of 4 (`tom_ocean_mesh`, `tom_crier`) hand-built a whole gen_server just to cast-serialize it. |
| RPC *advertise* (provider/responder) | **Declarative**, boot-wired — **the confirmed gap above** | Same shape as `capabilities()`/`store_id()` already: a service knows what it serves at boot. `macula_response:advertise_direct/6,7` is itself boot-declarable, same as an SDK "advertise" call. |
| RPC *call* (consumer) | **Imperative**, facade call | Already done (`call_capability`). No change. |
| Content, Streaming | **Neither, yet** | Zero DIY usage found in any of the four services. No repeated-pain signal exists to wrap against. Per this repo's own antipattern rules ("don't design for hypothetical future requirements") and the README's "outbound only, don't become a mesh framework" non-goal, **do not build these preemptively.** Both guides confirm the SDK-level shape is identical to RPC/PubSub (same `start_link`/`advertise` pattern, direct-dial available on both), so extending later is a known-cost, low-risk addition whenever a real DIY need shows up — not a reason to build it now. |

This gives a general rule, not just an answer for today's four primitives:
**whichever side is passive/receiving (subscribe, advertise/serve) wants
declarative boot-wiring; whichever side is active/initiating (publish,
call, get) wants an imperative facade call.** Apply this rule to Content/
Streaming if/when they're ever built, rather than re-deriving it.

### Question 5 — concrete definition adopted

"Most developer-friendly" = (a) fewest concepts beyond what
`hecate_om_service`'s existing optional-callback pattern already
teaches, and (b) a service author who's read the SDK's own Guides
recognizes the shape immediately. Concretely: a service declaring
`subscriptions() -> [{Topic, HandlerMod, Args}]` should feel exactly
like declaring `store_id()`/`data_dir()` today (optional callback,
`hecate_om:boot/1` wires it), and `HandlerMod` should be a **real
`macula_subscriber` callback module** — not a new hecate-om-invented
behaviour — so existing SDK knowledge transfers 1:1 and nothing new has
to be learned to use it.

### Question 6 — where this lives

Follow the `hecate_om_store.erl` precedent exactly (same repo, same
"ensure/N wiring helper dispatched by `hecate_om:boot/1` from an
optional callback" shape):

- **New `hecate_om_pubsub.erl`** — owns a supervisor for subscriber
  children; `ensure_subscriptions/1` dispatched from `hecate_om:boot/1`
  when the service exports optional `subscriptions/0`; exports
  imperative `publish/2,3`.
- **Extend `hecate_om_capabilities.erl`** (not a new module — RPC
  already lives there) with the missing provider-side responder wiring:
  when a service's `capabilities()` entries carry a handler module,
  `hecate_om:boot/1` should call `macula_response:advertise_direct/6,7`
  for each, in addition to the DHT `register/publish` it already does.
  This reuses `procedure_uri/3` (export it) for naming and the same
  `cert_chain_opts` logic already in `do_advertise/1` for direct-dial
  trust, so the provider side matches what `call_capability`'s
  `verify => true` consumer path already expects.
- **`hecate_om.erl` facade** gains `mesh_handles/0` and `publish/2,3`,
  and re-exports whatever `hecate_om_pubsub` needs surfaced — same
  pattern as capabilities being re-exported today.
- **Content/Streaming:** no new module. Document `hecate_om_content.erl`
  / `hecate_om_streaming.erl` as the known extension shape for when a
  real need appears; don't scaffold them now.

---

## Recommended design — summary

1. `hecate_om:mesh_handles/0` — shared `{Pool, Realm}` fetch, replaces
   four hand-rolled copies of the same pattern.
2. `hecate_om_pubsub:publish/2,3` — imperative, thin, off the caller's
   process.
3. `hecate_om_service` gains **optional** `subscriptions/0` callback
   (`[{Topic, macula_subscriber_module(), Args}]`) → `hecate_om:boot/1`
   dispatches to `hecate_om_pubsub:ensure_subscriptions/1`, which starts
   one `macula_subscriber` per entry under a supervisor it owns, and
   re-issues them when `hecate_om_identity`'s pool reconnects (closing
   the "pool restart doesn't auto-reattach subscribers" gap the SDK
   guide calls out explicitly).
4. `hecate_om_capabilities` gains the missing provider-side
   `macula_response:advertise_direct/6,7` wiring, closing the
   discoverable-but-not-callable gap, reusing the DHT-advertisement
   machinery already there.
5. Content and Streaming: explicitly deferred, not designed further,
   pending a real DIY need (same trigger this survey itself used — "a
   service is already reinventing it").
6. `call_capability`'s hand-rolled failover: kept as-is, not
   consolidated onto `macula_request:start_link_direct`.

**Not yet decided / needs the maintainer's sign-off before any code is
written:**
- Exact `subscriptions/0` tuple shape and whether `Args` is required or
  defaultable.
- Whether `capabilities()`'s existing `#{name, version}` shape grows a
  `handler` field, or whether provider wiring is a *second*, separate
  optional callback (`capability_handlers/0`) so producer-only /
  consumer-only services aren't forced to touch the existing
  `capabilities()` contract.
- Whether the README's "outbound only... not a network library" line
  needs updating given this closes a real gap in what's already a
  precedent-setting wrap (RPC), or whether the line already survives
  because "outbound only" was always about transport (no inbound
  listen socket), not about whether hecate-om wires SDK behaviours.

## Where to go next

This survey is done — six open questions answered, one confirmed gap
found that the original handover didn't know about (RPC provider-side
wiring). What's above is a design **recommendation**, not an approved
plan: **check the two "not yet decided" items and the overall direction
with the maintainer before writing any implementation plan or code.**
Once confirmed, this becomes a new `PLAN_HECATE_OM_MESH_WRAPPERS.md`
(or similar) covering the `hecate_om_pubsub` module, the
`hecate_om_capabilities` provider-side extension, and the `mesh_handles/0`
facade addition, sliced the way this repo already slices its other
optional-callback features (store wiring is the direct precedent to
follow for structure, tests, and docs).
