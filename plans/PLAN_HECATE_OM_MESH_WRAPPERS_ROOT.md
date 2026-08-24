# Plan: hecate-om Mesh Wrappers — Root / Handover

**Status:** Handover doc. The implementation content lives in
`plans/PLAN_HECATE_OM_MESH_WRAPPERS.md` — **read that doc for the actual
what/how**, this one is the repo-by-repo context, grep evidence, and
hard-won facts so a fresh session doesn't re-derive them. Mirrors
`hecate-tube/plans/PLAN_HECATE_TUBE_ROOT.md`'s own root/handover shape.
**Created:** 2026-08-24
**Read this first, then the plan doc.** Don't start writing code from
the plan doc alone — the two open design questions there are only
answerable after the survey this doc instructs.

---

## How we got here (compressed)

1. **2026-08-21/22** — `hecate-om/plans/PLAN_MACULA_API_INTEGRATION_SURVEY.md`: surveyed how to wrap macula's supervised primitives at the hecate-om level, using four then-known DIY repos as signal. Found one confirmed gap (RPC provider-side wiring missing) and a recommended design, deliberately **not implemented** — the call was to build one real, complete exemplar service first and derive the design from it instead of generalizing from fragments.
2. **2026-08-22/23** — `hecate-services/hecate-tube` built as that exemplar: a mesh video service deliberately mapping Streaming (all viewing), Content (thumbnails/logos), PubSub (integration facts), and RPC (catalog lookups) onto the four primitive pairs, built raw against the SDK on purpose. Now live and verified (`hecate-tube/plans/PLAN_HECATE_TUBE_ROOT.md`, `EVENT_STORM_HECATE_TUBE.md`/`_PART1`/`_PART2`).
3. **2026-08-24 (this session)** —
   - Re-verified the survey against current `hecate-om` source: recommendation #1 (`mesh_handles/0`) already shipped and committed (`0703da1`), a stale-template-pin bug hecate-tube found already fixed and committed. Recommendations #2–4 (pubsub wrapper, declarative subscriptions, RPC provider wiring) confirmed still absent.
   - Full-source audit of `hecate-tube`'s actual mesh-plumbing code (not just its planning docs) — see below.
   - Full-source audit of `macula` 10.1.1's actual supervised-wrapper layer — every one of six mesh capabilities (connect, pubsub subscribe/publish, RPC in/out, streaming, content) has a real, code-confirmed OTP behaviour wrapper, all of it 1–4 days old as of this session, landed in the same burst of work that split the SDK's docs into daemon-facing Guides vs. library-facing Protocol docs.
   - Read `macula_client.erl`'s actual `connect/2`/`child_spec/3` implementation directly, to answer whether `hecate_om_identity`'s hand-rolled connection management duplicates something the SDK already provides (it does, mostly — see "Key technical facts" below).
   - **Workspace-wide grep** across all 23 `hecate_om`-consuming repos for hand-rolled mesh wiring. This is new data the original survey didn't have — see the full table below. The pattern is far more widespread than four modules.
   - Wrote the implementation plan and this handover.

---

## Repos — role and status

### The SDK: `macula-io/macula`

Version **10.1.1**. The Guide/Protocol doc split (`docs/guides/{rpc,pubsub,content,streaming}/*_GUIDE.md` vs. the underlying Protocol docs) landed 9.13.4–9.13.8, 2026-08-21. Every supervised wrapper module (`macula_client`, `macula_subscriber`, `macula_publisher`, `macula_request`/`macula_response`, `macula_streamer`/`macula_stream_sink`, `macula_feeder`/`macula_download`, `macula_pusher`/`macula_upload`) is confirmed real, in code, with matching Guide docs stating it's "the supervised way" to do that thing. The whole set is very fresh (`macula_publisher` "as late as 9.4.0", `macula_pusher`/`macula_upload` at 9.13.0, both 2026-08-20/21) — treat it as young, not battle-hardened, when deciding how aggressively to lean on it.

### The substrate: `hecate-services/hecate-om`

Currently 0.15.0 (bumped this session for unrelated barrel_docdb read-model support — see `CHANGELOG.md`, a separate axis from this plan, don't conflate the two). `mesh_handles/0` ships. `hecate_om_capabilities` does DHT discovery (`put_record`) only, never `advertise_direct` — the confirmed provider-wiring gap. Zero PubSub or Content wrapping.

### The exemplar, fully audited this session: `hecate-services/hecate-tube`

Depends on `hecate_om ~> 0.14` for boot/mesh_handles/keypair only (three call sites total). Depends on `macula` **directly** for everything else — its own `rebar.config` comment states hecate_om "only wraps the RPC consumer side today". ~513 lines of hand-rolled mesh plumbing across 11 modules:

| Module | Primitive | Lines | What it does |
|---|---|---|---|
| `apps/query_tube/src/tube_mesh_providers.erl` | RPC + Streaming (provider) | 75 | Self-built `gen_server` calling `macula_response:advertise_direct/7` (×2) and `macula_streamer:advertise_direct/7`, its own 5s retry / 60s re-advertise timers, `reuse_sup` bookkeeping. **The template for plan piece B.** |
| `apps/query_tube/src/stream_video_clip_by_id/stream_video_clip_by_id.erl` | Streaming (business logic) | 69 | `-behaviour(macula_streamer)`, chunks a file. Service-specific, NOT a candidate for hecate_om absorption — only the advertisement half above is. |
| `apps/guide_tube_lifecycle/src/tube_content_put.erl` | Content | 42 | `-behaviour(macula_feeder)`, sync wrapper. **Template for plan piece E.** |
| `apps/guide_tube_lifecycle/src/tube_content_get.erl` | Content | 51 | `-behaviour(macula_download)`, sync wrapper. Carries the pooled-vs-direct lesson (see below). **Template for plan piece E.** |
| `apps/guide_tube_lifecycle/src/tube_mesh_publisher.erl` | PubSub (publish) | 13 | `-behaviour(macula_publisher)`, trivial fire-and-forget. **Template for plan piece C.** |
| `apps/guide_tube_lifecycle/src/channel_announcement.erl`, `video_clip_publication.erl` | PubSub (publish) | 50, 57 | Call sites using the publisher above. |
| (no subscribe usage anywhere in the repo) | PubSub (subscribe) | — | hecate-tube never subscribes. Adds zero evidence for plan piece D. |

Two non-obvious, hard-won lessons live only in this repo's comments right now — **both must survive into hecate_om or they'll get rediscovered the hard way again**:
1. **Wire-level ADVERTISE doesn't survive a reconnect.** A station's registration is tied to the connection that sent it. `tube_mesh_providers.erl` used to advertise once and go silently stale (`advertised => true` was local bookkeeping only). Fixed with a 60s re-advertise using `reuse_sup` (macula ≥10.1.0) to avoid leaking a supervisor per tick.
2. **`macula_download`'s direct-dial path only resolves chunked content.** Small blobs (a logo) never get a `content_announcement` DHT record, so `start_link_direct` 404s even right after upload — confirmed live on beam02. Put/get must both use the pooled `start_link/4,5`, not `_direct`.

Also: RPC/stream `args` decode with **atom** keys, not binary (macula's frame decoder round-trips through `binary_to_existing_atom/1`), re-solved independently in `stream_video_clip_by_id.erl` and `advertise_channel_lookup.erl` — the source for plan piece F.

### The original four DIY modules (per the 2026-08-21 survey — not re-read this session, re-verify before relying on them)

- `hecate-mpong-bot/src/hecate_mesh.erl`
- `hecate-tom-ocean/src/tom_ocean_mesh.erl`
- `hecate-tom-player/src/tom_wire_macula.erl`
- `hecate-tom-world/src/join_the_mesh/tom_crier.erl`

---

## Full grep results, all 23 `hecate_om`-consuming repos (2026-08-24)

Candidate universe (`grep -rl hecate_om */rebar.config`): hecate-archive, hecate-biotope, hecate-dns, hecate-dronex, hecate-embedder, hecate-git, hecate-grid, hecate-llm, hecate-mpong-bot, hecate-news, hecate-om, hecate-parksim, hecate-rag, hecate-robo-rumbler, hecate-sentinel, hecate-society, hecate-spartan, hecate-testkit, hecate-tom-ocean, hecate-tom-player, hecate-tom-world, hecate-tube, hecate-victron, hecate-warden.

**Provider-side wiring** (`advertise_direct`/`macula:advertise` — the confirmed RPC-provider gap pattern), **9 repos**, none of them hecate-tube's `tube_mesh_providers.erl` alone:

- `hecate-dronex/apps/hecate_dronex/src/join_the_archipelago/dronex_mesh.erl`
- `hecate-dns/src/hecate_dns_mesh_rpc.erl`
- `hecate-embedder/src/hecate_embedder_advertiser.erl` — **confirmed live in production**, serving hecate-spartan's real embed calls (see `reference_hecate_embedder_live` memory). Highest-signal repo to read for piece B — this pattern has survived real traffic, not just a smoke test.
- `hecate-git/src/hecate_git_mesh_rpc.erl`
- `hecate-llm/src/hecate_llm_mesh_rpc.erl`
- `hecate-rag/src/hecate_rag_mesh_rpc.erl` — note this one had a real bug (pre-barrel-migration dispatch shape, `undef` on every real caller) found only when hecate-spartan tried to call it live; see `project_hecate_rag_barrel_migration` memory. A cautionary example of what happens when this wiring is hand-rolled and only smoke-tested locally.
- `hecate-tom-ocean/src/tom_ocean_mesh.erl`
- `hecate-tom-world/src/join_the_mesh/tom_advertiser.erl`
- `hecate-tube/apps/query_tube/src/tube_mesh_providers.erl`

**PubSub subscribe** (`macula_subscriber`/`macula:subscribe`), **14 repos**:

- `hecate-archive/apps/hecate_archive/src/collect_observations/collect_observations.erl`
- `hecate-mpong-bot/src/hecate_mesh.erl`
- `hecate-parksim/apps/guide_charging_lifecycle/src/on_grid_price_changed_schedule_charging/on_grid_price_changed_schedule_charging.erl`
- `hecate-sentinel/apps/hecate_sentinel/src/ingest_warden_reports/ingest_warden_reports.erl`
- `hecate-spartan/apps/hecate_spartan/src/federation_ask.erl`
- `hecate-spartan/apps/hecate_spartan/src/federation_registry.erl`
- `hecate-spartan/apps/hecate_spartan/src/federation_agora.erl`
- `hecate-spartan/apps/hecate_spartan/src/federation_inbox.erl`
- `hecate-spartan/apps/hecate_spartan/src/inhabit_mind/spartan_mind.erl`
- `hecate-spartan/apps/hecate_spartan/src/inhabit_mind/convene_committee/committee.erl`
- `hecate-spartan/apps/hecate_spartan/src/inhabit_mind/convene_committee/committee_drone.erl`
- `hecate-testkit/src/hecate_testkit.erl` (+ its own tests)
- `hecate-robo-rumbler/apps/hecate_robo_rumbler/src/settle_visits/rumble_mesh.erl`
- `hecate-tom-ocean/src/tom_ocean_mesh.erl`
- `hecate-tom-player/src/tom_wire_macula.erl`

**hecate-spartan alone accounts for 6 of the 14** — by far the heaviest, most battle-tested pubsub consumer in the workspace, live and iterated on for months (its `federation_*` subsystem is the mesh-wide entity registry + message routing + agora, see `project_hecate_spartan` memory), not days like hecate-tube. **This is the repo to read before finalizing the `subscriptions/0` shape for plan piece D** — it will have hit edge cases (reconnect races, dedup, multi-topic fan-out) hecate-tube never had reason to.

**PubSub publish** (`macula_publisher`/`macula:publish`), **17 repos, 24+ modules** — by far the most repeated pattern of all, confirming plan piece C as the highest-volume win even though each individual instance is small:

hecate-archive, hecate-dronex, hecate-grid, hecate-mpong-bot, hecate-news, hecate-parksim (6 modules), hecate-sentinel (3 modules), hecate-spartan (7 modules — `federation_agora.erl`, `federation_registry.erl`, `maybe_register_entity.erl`, `maybe_route_message.erl`, `maybe_broadcast_message.erl`, `maybe_publish_to_agora.erl`, `maybe_report_activity.erl`, `committee_drone.erl`, `committee.erl`), hecate-testkit, hecate-victron, hecate-warden, hecate-robo-rumbler, hecate-biotope, hecate-society, hecate-tom-ocean, hecate-tom-world, hecate-tube (4 modules).

**Content** (`macula_feeder`/`macula_download`/`macula_pusher`/`macula_upload`), **only hecate-tube** (4 files) — consistent with the original survey's "no DIY signal yet" call for Content specifically; hecate-tube is the one real need that's appeared since.

---

## Explicit instruction for whoever picks this up next

**Status: items 1-3 below are DONE as of 2026-08-24 (session 2)** — full parallel survey of all 21 remaining `hecate_om`-consuming repos (everything in the candidate list except `hecate-om` and `hecate-tube`, both already audited), not just the two the handover called out as minimum. Findings are in the new section below. Items 4-5 remain relevant.

1. ~~Read `hecate-spartan`'s federation_*.erl~~ — done, see "Survey findings" below.
2. ~~Read `hecate-embedder/src/hecate_embedder_advertiser.erl`~~ — done, see "Survey findings" below. **Also corrected the reconnect-defense question this was meant to settle**: embedder uses plain `advertise/5`, which doesn't need periodic re-advertise at all (see corrected fact above) — its `macula_event_gone` re-advertise handler is very likely dead code.
3. ~~Skim the `*_mesh_rpc.erl` repos~~ — done for all four (dns/git/llm/rag), see "Survey findings" below.
4. Before writing code for piece B specifically, note that `hecate-rag/src/hecate_rag_mesh_rpc.erl` had a real production bug (dispatch shape drift after an internal refactor, `undef` on every live call, invisible to its own local tests) that was only found when another service tried to call it live — see `project_hecate_rag_barrel_migration` memory. This is direct evidence for the plan's testing-strategy section: a shared wrapper's correctness has to be verified against a real caller, not just its own unit tests. **Update:** the survey found `rerank_results` in that same module is *still* wired to a since-removed `evoq:dispatch/4` call today — a known-broken slice still live on the mesh. A shared wrapper wouldn't have prevented the original drift, but would eliminate the two-source-of-truth pattern (`capabilities()` vs `handler_table()`, see below) that made it possible to introduce silently.
5. Grep any remaining unlisted `hecate_om`-consuming repo for the same three patterns before assuming the table is exhaustive — still worth doing periodically, but the 2026-08-24 session-2 survey covered everything the session-1 grep found, plus confirmed `hecate-tom-general` has no `hecate_om` dependency at all (not in scope).

---

## Survey findings, 2026-08-24 (session 2) — full read of all remaining repos

Five parallel sub-surveys, one per repo group. Findings folded into "Key technical facts" above where they correct or generalize an existing claim; repo-specific detail follows here.

### hecate-spartan (piece D's primary evidence — 6 subscribe modules + ~10 publish call sites, months of live iteration)

- **No shared subscribe/publish abstraction exists anywhere in spartan** — every module hand-rolls the same `self() ! subscribe` → `macula:subscribe/4` idiom and the same `case {client(),realm()} of ...` publish guard, independently, ~10+ times.
- **Two different resubscribe strategies coexist, not one**: push-reactive on `{macula_event_gone, Ref, Reason}` (`federation_registry`, `federation_agora`, `federation_ask`, `spartan_mind`, `committee`, `committee_drone`) vs. pull/timer-only reconcile (`federation_inbox`, 5s tick, no `macula_event_gone` handling at all). A wrapper that only offers one of these would regress whichever set of modules doesn't get its style.
- **`federation_inbox` needs a dynamic, changing topic set** (one topic per locally-homed entity, reconciled every 5s against `hecate_spartan_entities:all()`), not a static list wired once at boot — piece D's `subscriptions/0` needs a first-class reconciliation operation, not just one-shot registration.
- **`committee.erl` documents a real edge case**: a resubscribe can legitimately re-fire business logic (`open_floor/1`) for the same turn, requiring an explicit cancel-then-rearm timer guard — consumers of a resubscribing wrapper must expect *logical* double-fires around reconnect, not just physical duplicate messages.
- **Dedup is domain-specific everywhere it appears** (`post_id`, `{recipient,msg_id}` via a separate inbox module, natural upsert idempotency, floor-controlled turn-taking) — piece D should not try to centralize this.
- **The "dark mesh is not an error" guard idiom** (`case {client(),realm()} of {{ok,_},{ok,_}} -> ...; _ -> ok end`) is the most-repeated pattern in the whole repo on both subscribe and publish sides — worth baking into `hecate_om_pubsub` as first-class behavior.
- No module anywhere calls `macula:unsubscribe` — teardown is process-death-only.

### hecate-embedder + the `*_mesh_rpc.erl` quartet (dns/git/llm/rag) — piece B's primary evidence

- **`capabilities()`/handler wiring is already drifting in production, in both directions, right now:**
  - `hecate-dns`, `hecate-git`, `hecate-llm`: `capabilities() -> [].` (still a literal `%% TODO` stub) while their `*_mesh_rpc.erl` fully advertises 5-10 real callable procedures — callable but invisible to DHT discovery.
  - `hecate-rag`: `capabilities()` is a **second, independently hand-typed list** duplicating `handler_table()`'s procedure names — two sources of truth, manually kept in sync. This is the exact shape of drift that produced the `rerank_results` breakage above.
  - `hecate-embedder`: the one populated `capabilities()` entry (`<<"embed">>`) doesn't even match the real advertised procedure string (`<<"io.hecate.embed">>`) — a name mismatch in the one repo that tried.
  - **This is strong, concrete evidence for the plan's open question: `capabilities()` should carry the handler inline as one source of truth**, not a parallel hand-maintained list.
- **Handler declaration shape**: dns/git/llm/rag use `{Module, FunctionAtom}` tuples; embedder uses a bare `fun ?MODULE:handle_embed/1` reference. `hecate-tom-world`'s `tom_advertiser.erl` (separate sub-survey, below) gives the reason to prefer MFA tuples: a captured fun pins the registering module's code version, so a hot-upgraded desk keeps answering with old code. **Should be a hard requirement in piece B, not a style choice.**
- **Wire-args decode contradiction found**: `hecate-embedder`'s `gf/2` tries atom keys first, falling back to binary (matches the established hecate-tube finding). But **dns/git/llm/rag's `route/2` handlers pattern-match binary keys only, zero tolerance** — if live mesh calls actually decode with atom keys (as three hecate-tube files and embedder's own defensive code assume), these four services' handlers would fail to match on real traffic. Unverified live, but cheap and worth checking before piece F is finalized.

### hecate-tom-ocean / hecate-tom-world / hecate-tom-player / hecate-dronex (re-verification of the original 4 DIY modules + dronex)

- `hecate-tom-general` checked and confirmed **out of scope** — no `hecate_om` dependency, no macula code.
- **`tom_ocean_mesh.erl`'s reconcile-on-timer is conditional, not blind**: only re-advertises on a detected pool-pid change (via `erlang:monitor`/`DOWN`) or a prior failure, driven by `macula_event_gone` plus the monitor — closer to the right long-term design for piece D than hecate-tube's periodic-blind-resend.
- **`tom_advertiser.erl` shows no reconnect defense of any kind** — advertises once at init, schedules nothing further on success. Whether this is a live bug or a non-issue depends on which advertise flavor it uses (see the corrected fact above) — needs to be resolved before piece B design is final, not assumed either way.
- **MFA-pair handler registration** (`tom_advertiser.erl`) — see above, folded into piece B requirements.
- **`tom_wire_macula.erl`'s `classify/1`** builds an RPC-outcome retryability taxonomy by asking `macula_bolt4:is_retryable/1` rather than duplicating the BOLT#4 code table locally — a candidate second shared helper alongside piece F, on the response side rather than the request-args side.
- **`dronex_mesh.erl` confirms realm-per-topic off one pool** (public vs. fleet realm) — third independent confirmation of the dual-realm requirement (with robo-rumbler and biotope/society).
- **Inconsistent defense against the piece-A boot race**: present in `dronex_mesh.erl` (try/catch around `hecate_om_identity:macula_client()`), absent in `tom_advertiser.erl` (same call, unguarded) — direct evidence that `hecate_om` itself should guarantee non-raising accessors rather than leaving each caller to (inconsistently) defend itself.

### hecate-archive / hecate-parksim / hecate-sentinel / hecate-mpong-bot / hecate-robo-rumbler / hecate-testkit

- **`hecate-mpong-bot`'s `hecate_mesh.erl` is already a small, generic `hecate_om_pubsub`-shaped facade** (publish/subscribe/unsubscribe over pool+realm, degrade-to-`{error, mesh_unavailable}`, plus a callback-fun subscribe option none of the other repos have) — the closest existing prior art for piece C/D's shape; worth reading directly as a starting skeleton, not just citing.
- **Both `hecate_mesh.erl` and `rumble_mesh.erl` deliberately push resubscribe-on-churn to the caller**, documented as a vertical-slice-ownership design stance ("each subscribing slice is responsible for re-subscribing... there is no central subscription manager") — a real, deliberate alternative to centralizing reconnect handling in piece D, not an oversight to fix.
- **`hecate-parksim` uses a wildcard subscribe** (`<<"energy/+/grid_price">>`) — the only wildcard instance found in the whole survey; confirm piece D's API supports wildcard topics, don't assume literal-only.
- **`hecate-sentinel` independently invented a heartbeat-as-liveness-beacon** — a periodic fact carrying only `{epoch, seq}`, published specifically to convert "silently deaf forever" into "detectably deaf within one period." This solves the same reconnect-blindness problem the plan already tracks, via a different mechanism than `macula_event_gone` — worth considering as an opt-in piece D/C feature.
- **`hecate-archive` implements a bounded dedup window** (`{seen, order}` capped at 20000, oldest-evict) for at-least-once delivery — heavier than anything else seen, domain-specific (key is `{source,dataset,epoch,seq}`), not a generalization candidate but evidence piece D's design should leave room for consumer-owned dedup rather than assuming none is needed.
- **`hecate-sentinel` derives deterministic idempotent IDs** (sha256 of business fields) so redelivery naturally resolves to the same aggregate stream instead of relying on transport dedup — same lesson as archive's, independently arrived at, worth a one-line mention if a "how to handle redelivery" note ever gets written.
- **`hecate-testkit`'s `with_mesh/1,2` + `publish/3` + `subscribe/2` + `await/2,3`** is real, live, in-memory-mesh test infrastructure (only `hecate_om_identity` is meck'd, not macula itself) — already built, matches the plan's testing-strategy note about real round-trips over mocks. **Recommendation: this should become the blessed way every future `hecate_om_pubsub`/`hecate_om_service` consumer tests its own mesh code**, not a standalone library only some repos happen to use.
- **`rumble_mesh.erl`'s dual-realm bug lesson**: an early version let a bad `{error,_}` tuple flow through as a realm value and crashed inside `macula:subscribe` while a health/`available/0` check still reported `true` — "the health check lied." Any status/health surface piece B or D exposes must reject error tuples explicitly, not accept-by-default in a catch-all clause.

### hecate-grid / hecate-news / hecate-victron / hecate-warden / hecate-biotope / hecate-society (publish-only breadth check)

- **The "trivial and uniform, `macula_publisher`-behaviour-shaped" assumption from hecate-tube breaks completely**: 0 of 6 use the behaviour; all 6 call `macula:publish/4` directly and synchronously.
- **Three different, all-live error-handling philosophies for a failed publish**: silent swallow (`hecate-grid`), log-and-continue (`hecate-victron`, `hecate-warden` — both explicitly re-added this after an earlier version silently ate refused frames), and return `{error, term()}` to the caller (`hecate-biotope`/`hecate-society`). Piece C's API needs to support at least silent + return-error, not force one.
- **`hecate-news` fans one fact out to up to 4 topics per call** (a firehose topic plus per-axis sub-topics) — piece C's signature should comfortably support "publish this to N topics," not assume 1:1.
- **`hecate-biotope`/`hecate-society` are ~170-180 lines of near-duplicated logic across two repos**, including a documented bug-fix re-applied by hand in both places — direct evidence of the maintenance cost this duplication causes, not just a line-count argument.
- Confirms (third independent source, with robo-rumbler and dronex) that dual-realm publish is a real deployed access-control pattern, not an edge case.

---

---

## Key technical facts already established (don't re-derive)

- **`macula_client:child_spec/3`** (`connect/2` as the start MFA) returns immediately even with zero seeds connected; each seed link dials independently and retries forever on its own timer without touching the supervisor. This already does most of what `hecate_om_identity`'s hand-rolled reconnect logic does. Whether `hecate_om_identity`'s claimed boot-race ("hecate_om may start before macula is fully up") is still real is unconfirmed — verify by attempting the migration (plan piece A), don't assume either way. **Update:** the broader survey (below) found three services (`hecate-biotope`, `hecate-society`, `hecate-dronex`) defending against exactly this race today with hand-rolled try/catch around `hecate_om_identity:macula_client()` — real code treats it as real even if release-boot ordering prevents it. Strongest fix: make `hecate_om`'s own accessors return `{error, not_booted}` instead of raising `noproc`, which obsoletes the hand-rolled defenses everywhere at once rather than confirming/denying the race per call site.
- **CORRECTED — was stated too broadly.** "Wire-level ADVERTISE does not survive a reconnect" is only true for **`advertise_direct`** (`macula_streamer:advertise_direct/6,7`, `macula_response:advertise_direct/6,7` — direct-dial registration for streaming/content, tracked in the connection-scoped `macula_remote_advertise_registry`). **Plain `macula:advertise/5` (`macula_client:advertise/4,5`, used for ordinary RPC handler registration) is stored in pool state and auto-replayed on every link respawn** via `on_respawn_link/2` → `macula_client_replay:advs_to/2` — confirmed by reading `macula_client.erl` directly in the broader survey. `reuse_sup` re-advertising is only needed for the direct-dial path (hecate-tube's actual use case, streaming). The four `*_mesh_rpc.erl` services (dns/git/llm/rag) all use plain `advertise/5` and correctly need no reconnect defense at all — they were never buggy. **Open reconciliation item:** `tom_advertiser.erl` (hecate-tom-world) and `dronex_mesh.erl` (hecate-dronex) show no reconnect defense either — whoever picks up piece B must first determine which advertise flavor each one actually uses before concluding they carry the bug or are fine.
- **`macula_download`'s direct-dial path only resolves chunked content** — small blobs need the pooled `start_link/4,5`, not `_direct`. Source: `tube_content_get.erl`, confirmed live on beam02.
- **RPC/stream `args` decode with atom keys, not binary** (macula's frame decoder). Source: `stream_video_clip_by_id.erl`, `advertise_channel_lookup.erl`. **Update:** the broader survey found this is much bigger than RPC/stream args — `hecate-spartan` reimplements atom/binary tolerance for **pubsub payloads** 11+ times (`mget/2,3` helper, copy-pasted). And `hecate-dns/-git/-llm/-rag`'s `route/2` handlers pattern-match **binary keys only, with zero tolerance** — contradicting the atom-key finding and hecate-embedder's own defensive `gf/2` helper. This is an unverified-live but plausible bug risk across four production services; cheap to check before writing piece F.
- **The `*_mesh_rpc.erl` naming convention has emerged independently in at least four repos** (`hecate_dns_mesh_rpc`, `hecate_git_mesh_rpc`, `hecate_llm_mesh_rpc`, `hecate_rag_mesh_rpc`) — confirmed load-bearing and near-identical (same `advertise_all/0` → `handler_table/0` → `route/2` → `delegate/3` skeleton, same graceful-degradation comment verbatim) across all four, not a naming coincidence. hecate_om's design should make this module unnecessary.
- **CORRECTED, second pass this session.** No repo besides hecate-tube uses the `macula_publisher` OTP behaviour — every other publish call site (~23 repos, dozens of modules) calls `macula:publish/4` directly, wrapped in `case {hecate_om:macula_client(), hecate_om_identity:realm()} of {{ok,Pool},{ok,Realm}} -> catch macula:publish(...), ok; _ -> ok end`. **This is not evidence piece C should wrap the raw call — it's evidence of what `hecate_om` giving services nothing better produces.** `src/macula_publisher.erl` was read directly this session: it already takes `Pool`/`Realm`/`Topic` as plain arguments (realm-override isn't a gap), delivers the outcome to a caller-controlled callback (silent/log/return-to-caller are three one-line `handle_published/2` bodies, not three designs), and auto-publishes `pubsub.publish_started_v1`/`_completed_v1` lifecycle facts none of the ~23 hand-rolled sites get today. Piece C should be built on `macula_publisher`; see the plan doc's corrected piece C.
- **Dual-realm publish (fleet realm + a separate business/public realm off the same pool) is a real, independently-confirmed deployed pattern** — found in `hecate-robo-rumbler` (`rumble_mesh.erl`), `hecate-biotope`/`hecate-society` (public web container must never hold the fleet tag), and `hecate-dronex` (`dronex_mesh.erl`, realm-per-topic). Pieces B/C/D must accept an explicit realm override, not hardcode `hecate_om_identity:realm()`.
- **RESOLVED, second pass this session — read `src/pubsub/macula_subscriber.erl` and `src/client/macula_client_replay.erl` directly.** `macula_client_replay:subs_to/2` mirrors `advs_to/2` exactly: on every link respawn, the pool re-issues a SUBSCRIBE frame for every tracked `{Realm, Topic}`, same `SubRef`, no caller action. **Plain subscriptions auto-replay on link respawn, just like plain advertise does** — a `macula_subscriber` process never even sees a respawn. `macula_event_gone` is the signal for a *genuine* loss (pool `macula:close/1`, station-initiated unsubscribe), and `macula_subscriber` already turns it into `{stop, Reason, State}` — under an ordinary OTP supervisor (`transient`/`permanent` child), that's the entire reconnect story: crash, restart, `init/1` re-subscribes. **This means most of the hand-rolled reconnect machinery catalogued below (spartan's push-on-`macula_event_gone`, `tom_ocean_mesh.erl`'s pool-`DOWN` monitor) is defending against something the pool already resolves one layer down.** It's not evidence for how piece D should detect reconnects — it's a list of code piece D makes redundant. See the plan doc's piece D, corrected on this basis. The dynamic-topic-set requirement (`federation_inbox`) is real and separate — a supervision-membership problem (`ensure_subscriptions/1` diffing desired vs. running children), not a reconnect-detection problem.
  **CONFIRMED LIVE, not just read**: `macula-io/macula/test/macula_link_respawn_replay_tests.erl` (written this session, currently uncommitted) boots a real pool + link against an unreachable seed, kills the link, and proves via `meck` tracing on `macula_station_link:subscribe/4` that the replay genuinely re-issues the subscription on the new link — no `macula_event_gone`, event delivery keeps working under the same `SubRef`, zero action from the subscriber. 2.5s, passed. Candidate for a permanent SDK regression test; needs sign-off to commit.
- **Both `tom_advertiser.erl` and `dronex_mesh.erl` confirmed (by direct code read, no live check needed) to use plain `macula:advertise/4,5`, not `advertise_direct`** — `tom_advertiser.erl:78`, `dronex_mesh.erl:98`. Neither repo carries the reconnect-loss bug; both are as safe as `dns`/`git`/`llm`/`rag`. This closes the plan's last open item.
