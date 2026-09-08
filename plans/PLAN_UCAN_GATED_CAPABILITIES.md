# PLAN: UCAN-gated mesh capabilities, shared instead of hand-rolled

Status: **Implemented**, extended 2026-09-08 to a policy this plan's own
"What's open" section had called unbuilt. `hecate_om_capabilities:register/1`
accepts an `auth` key per capability; the shared path (`auth_opts/1`) was
already policy-agnostic, so adding the new variant to
`hecate_om_service:capability/0''s type was the whole fix — see "Update,
2026-09-08" below. What's left is per-service adoption — see "What's
open."

## Update, 2026-09-08: `realm_member_required` closes the gap this plan called unbuilt

This plan's own "What's open" (below, kept for history) said plainly:
"the fuller `HECATE_AUTH_MODEL.md' vision (any realm member's individually
delegated, revocable agent) needs... chain-walking verification, which
doesn't exist anywhere in `macula` today." That's no longer true —
`macula` added `{realm_member_required, RealmDid, RequiredCan}` to
`macula_client:auth_policy/0'`: a valid token signed by the realm's own
DID, audience-bound to the wire-authenticated caller (closing the same
bearer gap `ucan_required` doesn't), at a specific, mandatory membership
tier (a realm mints membership at more than one tier from the same
signing key — see that type's own moduledoc).

`hecate_om_capabilities:auth_opts/1' needed no change at all: it was
already written to forward whatever value a capability's `auth' key
holds without inspecting which variant it is (see its own doc). The only
real gap was `hecate_om_service:capability/0''s own type, which still
enumerated only `open | {ucan_required, _}' — a hecate-nvidia-pair
implementation the same day used `{realm_member_required, ...}' by
bypassing this module entirely (calling `macula:advertise/5' itself),
purely because the type made it look unsupported through the normal
path. Fixed: the type now includes the third variant, this module's own
moduledoc explains both gated policies, and a new eunit test
(`auth_opts_carries_a_realm_member_required_policy_test`) pins that it
round-trips identically to the other two.

**Rollout-safety follow-on (2026-09-03, same repo):**
`hecate_om_capabilities:unguarded_capabilities/1` + `scripts/audit-fleet-ucan-adoption.sh`
(CHANGELOG `[Unreleased]`) — the audit half of not silently missing a
service when this rolls out fleet-wide. Sequenced as Phase 4 of
`macula-io/macula-architecture/plans/PLAN_CLOSE_SERVICE_AUTH_GAPS.md`,
which also found that no client SDK can present a UCAN over direct-dial
yet — this module's own gating has nothing a polyglot caller can attach a
token to until that SDK-side gap closes.

## Goal

A hecate-service should be able to mark a specific mesh capability as
requiring a UCAN issued by a known identity — e.g. only an operator can
call `hecate-rag.prune_chunks` — using the auth-policy primitive
`macula` already provides, through the shared registration path every
hecate-service already has available, not a hand-rolled one.

## What's real (verified against source)

- **`macula:advertise/5` already supports gating.** Its `Opts` map reads
  an `auth` key: `open` (default) or `{ucan_required, Issuer}`
  (`macula.erl`), threaded into `macula_client:advertise/5` and enforced
  on every inbound call by `macula_station_link:authorize_policy/2` →
  `check_ucan/2` → `macula_ucan_nif:verify(Token, Issuer)` — a direct
  signature check against one exact issuer pubkey, not a walk of a
  token's `proofs` chain to some ancestor delegator. It fits "only this
  one known identity may call this" today; it does not fit "anyone whose
  UCAN traces back to a trusted realm root, however many delegation hops
  deep" without separate, unbuilt chain-walking verification.
- **`hecate_om_capabilities:register/1` was already the shared path —
  it just never extracted `auth`.** `register/1` → `do_advertise/2` →
  `advertise_one/7` calls `macula_response:advertise_direct/7` per
  capability, whose own moduledoc confirms its `Opts` map is "forwarded
  BOTH to `advertise/6` (so `announce`/`auth`/`reuse_sup` apply here
  too)" — the gating primitive was already wired all the way through
  this shared function. `advertise_one/7`'s capability-map pattern
  (`#{name := Name, handler := {Mod, Args}}`) simply never read an
  `auth` key from the map to merge into the `Opts` it builds.
- **`hecate-rag` bypasses this shared path entirely.** Its
  `hecate_rag_mesh_rpc.erl` hand-rolls its own `advertise_all/0` →
  `advertise_each/2` → `advertise_one/3`, calling `macula:advertise/5`
  directly with a hardcoded `#{}` for all 15 of its capabilities — never
  through `hecate_om_capabilities:register/1` at all, so it never had
  access to `auth`, org-scoped dual-registration, or DHT-record
  publishing the shared path already provides for free.

## What this plan built

- `hecate_om_service:capability/0` gained an optional `auth` field:
  `open | {ucan_required, <<_:256>>}`.
- `hecate_om_capabilities:auth_opts/1` (exported, pure): extracts a
  capability's `auth` key into the map `advertise_one/7` merges into
  `Opts`, defaulting to absent (equivalent to `open`) when a capability
  sets none — matching every existing caller's behavior unchanged.
- `advertise_one/7` merges `auth_opts(Cap)` into both the bare and
  org-qualified `Opts` maps it already builds, alongside the existing
  cert-chain and `reuse_sup` merges.
- 3 new eunit tests for `auth_opts/1` (absence, explicit `open`,
  `{ucan_required, Issuer}`); full suite (85 tests) and dialyzer both
  clean.
- `hecate_om_simple_handler` (new module): migrating a capability from
  bare `macula:advertise/5` onto `register/1` hit a real contract
  mismatch discovered doing exactly that for `hecate-rag` — `macula`'s
  native handler is a direct `{Module, Function}` call, but
  `macula_response:advertise_direct/7` (what `register/1` uses) spawns a
  per-request gen_server expecting `Module:init/1` +
  `Module:handle_request/2`. This bridges a stateless one-arity handler
  into that contract, unwrapping an `{ok, _}` reply itself so the two
  layers' independent `{ok, _}`-handling doesn't compose into a
  double-wrapped wire payload. 4 tests pin that exact behavior.
- **`hecate-rag` migrated.** All 15 capabilities now advertise and
  dispatch through `hecate_om_capabilities:register/1` via
  `hecate_rag_service:capabilities/0`'s own `handler` key
  (`{hecate_om_simple_handler, {hecate_rag_mesh_rpc, HandlerFun}}`) —
  `hecate_rag_mesh_rpc`'s own `advertise_all/0` hand-rolled loop is
  deleted. Verified: full `rebar3 compile` clean against a local
  `hecate_om` checkout (this isn't released yet — see hecate-rag's own
  CHANGELOG). Its Common Test suite has a pre-existing, confirmed
  (A/B'd against the unmigrated code) `init_per_suite` failure unrelated
  to this change — not something this migration caused or fixed.

## What's open — not decided here

- **Releasing this `hecate_om` version** so `hecate-rag`'s `rebar.config`
  can move off its temporary `_checkouts/hecate_om` local-dev symlink.
- **Every other hecate-service still hand-rolling its own advertise
  loop** (outside `hecate-rag`) has the same gap `hecate-rag` just
  closed — not this plan's scope to find and migrate all of them.
- **Which capabilities get gated, and to which issuer**, is a
  per-service decision. Candidates once hecate-rag migrates:
  `prune_chunks`, `schedule_reembed` — corpus-mutating, operator-only —
  not `answer_query` or `search_chunks_semantic`, which should stay
  open.
- **Superseded by the 2026-09-08 update above**: `{ucan_required, Issuer}`
  still gates to one exact identity by direct signature only, but the
  "any realm member" case this bullet called unbuilt now has a real
  primitive (`realm_member_required`) — see that update for what it
  covers and what it still doesn't (a *tier*, not arbitrary delegation
  depth within a tier).
