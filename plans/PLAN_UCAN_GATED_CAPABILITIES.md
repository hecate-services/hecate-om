# PLAN: UCAN-gated mesh capabilities, shared instead of hand-rolled

Status: **Implemented.** `hecate_om_capabilities:register/1` accepts an
`auth` key per capability; 33 tests pass in this module (85 across the
app), dialyzer clean. What's left is per-service adoption — see "What's
open."

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

## What's open — not decided here

- **`hecate-rag` still hand-rolls its own advertise loop** and gets none
  of this for free until it migrates onto
  `hecate_om_capabilities:register/1`. That migration is valuable — it
  also gets org-scoped dual-registration and DHT publishing hecate-rag
  currently does without — but is separate work this plan doesn't do.
  Every other hecate-service using the same hand-rolled pattern has the
  same gap.
- **Which capabilities get gated, and to which issuer**, is a
  per-service decision. Candidates once hecate-rag migrates:
  `prune_chunks`, `schedule_reembed` — corpus-mutating, operator-only —
  not `answer_query` or `search_chunks_semantic`, which should stay
  open.
- **The confirmed boundary stands**: `{ucan_required, Issuer}` gates to
  one exact identity by direct signature, not a human-membership-rooted
  chain of arbitrary delegation depth. The fuller `HECATE_AUTH_MODEL.md`
  vision (any realm member's individually delegated, revocable agent)
  needs that chain-walking verification, which doesn't exist anywhere
  in `macula` today — a different, larger, unscoped piece of work.
