# PLAN: Ownership proof v2, once, in hecate-om

**End goal:** a service can check that a citizen authorised exactly this
request, or exactly this fact, without trusting whoever relayed it.

**BUILD**, not a claim. Rough size: one hecate-om release, two client
releases, four service changes.

## Today (v1)

The same scheme has four copies:

| Module | Repo | Used by | Caller bound |
|---|---|---|---|
| `hecate_om_ownership_proof` | hecate-om | hecate-graph `learn_link` (`asserted_by`) | no, by design: `asserted_by` exists for relays |
| `citizen_ownership_proof` | hecate-citizens | `register_presence` | yes, in the responder (d7a60bd, local) |
| `mailbox_ownership_proof` | hecate-mail | `get_mailbox`, `get_letter`, `reply_to_letter`, `archive_letter` | yes, `verify/4` (local) |
| `room_ownership_proof` | hecate-mods | `invite_agent_to_room`, checked in `room_aggregate` | no: `requester_node_id` comes from the payload |

- **Message:** `identity (32 bytes) ++ timestamp (8 bytes BE) ++ procedure`, with 60 s of skew.
- **Payload fields:** none are covered. hecate-mods binds room and target by folding them into the procedure string.
- **Signers:**
  - macula-mcp: `ownership_proof.ts`, `signOwnershipProof` (Venus).
  - macula-cli: `identity sign` (Venus).
  - hecate-spartan: `citizen_registration`, `mind_tools` `asserted_by` (retired).

## What v2 fixes

1. **Field coverage.** A proof signs the fields it authorises. A captured
   proof cannot be reused with another `letter_id`, another display name, or
   another triple, even by its own caller's relay.
2. **One caller binding,** instead of one per service.
3. **Domain separation.** v2 bytes can never verify as a v1 message or as any
   other signed structure.
4. **Signed facts.** A `citizen_presence` fact carries the owner's own proof,
   so a receiving instance checks the citizen, not only the publishing
   instance.

## Message

The message is the deterministic CBOR (RFC 8949 section 4.2.1) of the map below. It uses the
encoder macula already uses for publisher signatures
(`macula_cbor_nif:pack_deterministic`).

    #{domain    => "hecate.ownership_proof.v2",
      scope     => Scope,       %% procedure name for a CALL
      identity  => Identity,    %% raw 32-byte Ed25519 public key
      timestamp => Ms,          %% integer, milliseconds
      fields    => Fields}      %% text keys; text, integer or list-of-text values

- **Named fields, never the payload.** `Fields` holds exactly the named
  fields a handler acts on, built the same way by signer and verifier. A
  verifier never signs over "whatever arrived".
- **Test vectors ship in hecate-om:** a fixed seed, inputs, message hex and
  signature hex. macula-mcp and macula-cli run the same vectors, which also
  proves the TS and Go deterministic CBOR encoders agree with macula's.

## hecate-om API

`hecate_om_ownership_proof:verify(#{identity, proof, scope, fields, caller})`

- `caller => Caller`: also requires `identity =:= Caller`. This is a request
  on the caller's own behalf, and the default.
- `caller => none`: no caller binding, named explicitly. It is allowed only
  for signed data whose proof covers every field and the expiry, such as a
  citizens fact that an instance publishes for its owner. It is **data
  authority, never action authority**: it shows what the owner registered,
  not that anyone may act as them. With `asserted_by` removed, citizens facts
  are its only user.
- **Errors:** `invalid_identity`, `missing_proof`, `bad_signature`,
  `stale_proof`, `identity_is_not_the_caller`.
- **Freshness:** 60 s of skew for a CALL. A fact passes its own window: a
  timestamp more than 60 s ahead is refused, and its age is bounded by the TTL
  its fields name.
- `message/1` is exported for signers and tests.
- **v1 during the transition:** it stays available as `verify_v1/4`, caller
  bound, then is deleted.

## Consumers

| Service, procedure | Fields | Caller |
|---|---|---|
| citizens `register_presence` | `ttl_ms`, `citizen_kind`, `display_name`, `offers` | bound |
| citizens `citizen_presence` fact | the same proof, carried in the fact; the listener verifies it with the same scope, fields and expiry | `none` (data authority), plus the instance list |
| mail `get_mailbox` | none | bound |
| mail `get_letter`, `archive_letter` | `letter_id` | bound |
| mail `reply_to_letter` | `letter_id`, `subject`, `body` | bound |
| mods `invite_agent_to_room` | `room_topic`, `target_node_id`, `purpose` | bound: the requester is the caller |
| graph `learn_link` (`asserted_by`) | none | removed before v2, in its own hecate-graph commit, red first |

Each service deletes its own proof module and calls hecate-om.

For citizens, the signed timestamp becomes the registration time. Ordering by
it removes the rollout-only `decide/2` clause and the trust in a listed
instance's clock.

## Order

1. **hecate-om:** v2, the test vectors, and `verify_v1/4`. Vulcan reviews,
   then Raf publishes to hex.
2. **Clients sign v2 with fields,** then release:
   - macula-mcp (Venus);
   - macula-cli (Venus), with `identity sign --field key=value`.
3. **Services,** each red first and each reviewed by Vulcan. Each accepts v2,
   and v1 caller-bound only, through one hecate-om call.
4. **Citizens:** facts carry the owner's proof, and the listener verifies it.
   The instance list stays, as a spam bound.
5. **Remove v1** from the services and from hecate-om. This happens once both
   clients have released and a live check shows v2 in use.

## Decisions (2026-09-11)

- **`learn_link` `asserted_by`:** removed. Raf decided. It gets its own small
  hecate-graph commit, red first: a relayed assertion is refused.
- **v1 lifetime after the client releases:** until the next hecate-om minor,
  gated by a live check that v2 is in use.
- **hecate-mods caller binding:** now, on v1, like mail. Red first, with the
  client check first.
- **Unbound verification** is explicit (`caller => none`), limited to signed
  data that covers every field plus expiry, and documented as data authority.
