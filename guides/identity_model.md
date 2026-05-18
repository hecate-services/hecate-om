# Identity model

## The picture in plain language

Think of the **realm** as a small town.

- **Citizens** of the town are users. Each carries a citizen ID (a
  realm-issued personal cert). The town clerk (hecate-realm) signs
  these IDs.
- The town also has **institutions**: the library, the post office,
  the water utility. Each institution has its own **staff badge**,
  also signed by the clerk. The library doesn't borrow Alice's
  citizen ID to lend her a book — it acts as *"the library, on
  behalf of the town"*.
- Citizens and institutions are both legitimate town members, but
  they have **different kinds of identity**:
  - Citizens are mortal, mobile, and present an ID when they want to
    do something personal.
  - Institutions are persistent, fixed, and act for the town.
- If Alice leaves town for a month, the library keeps lending books.
  If a librarian retires, the library hires another — the badge
  stays with the building, not the person.

A Hecate service (`hecate-rag`, `hecate-llm`, `hecate-dns`, …) is an
**institution**. It has its own keypair and its own realm-signed
credential. It runs on infrastructure the realm owns (the BEAM
cluster, dedicated relay boxes, cooperative-contributed service
nodes) — never on a citizen's personal laptop.

## In Hecate

- `hecate-realm` (or `macula-realm`) is the **clerk** that mints
  credentials for both citizens (humans) and institutions
  (services).
- Each `hecate-services/hecate-X` deployment registers a **service
  principal** with the realm at install time. The realm signs a
  long-lived credential authorising it for a declared scope.
- The credential is provisioned onto the node via the existing
  `hecate_realm_session:provision_from_inherited_creds/2` flow (the
  same path headless beam nodes use to join their realm — see memory
  `project_realm_identity_rethink`). The credential lives in
  `/etc/hecate/secrets/{{service_name}}/`.
- At boot, the service container mounts that directory and reads its
  cert. `hecate_om_identity` caches the cert and hands a Macula
  client handle to the rest of the service.
- All requests the service makes to other peers carry the service-
  principal cert. Stations and other services verify *"signed by the
  realm? scoped to {{service_name}}? allowed for this action?"*

## What citizens (users) do

Citizens **call** services through the mesh. Alice's
`hecate-daemon` issues an RPC like:

```
macula:call(local-station, <<"hecate-rag.query">>, Query, Timeout)
```

The station routes it to wherever `hecate-rag` runs (most likely
beam00 or a relay box). `hecate-rag` answers as itself, the realm
verifies Alice's right to ask (her citizen cert), and the answer
flows back.

Authorisation has **two sides**:

1. The **caller's** credential (Alice's cert) proves they're allowed
   to ask the question — was the corpus visible to them, are they a
   realm member, etc.
2. The **service's** credential proves it's allowed to answer for
   the realm — was it provisioned by the realm clerk, is its scope
   correct.

Neither side borrows the other's credential. They each present
their own and the realm-rooted trust graph does the rest.

## Service-principal scope

When a service's `identity_spec/0` returns:

```erlang
identity_spec() ->
    #{
        scope     => <<"hecate-rag">>,
        actions   => [<<"publish_summary">>, <<"answer_query">>],
        resources => [<<"corpora/*">>],
        ttl_days  => 365
    }.
```

it's telling the realm clerk *"mint me a credential that lets me do
exactly this, and nothing else"*. The realm checks the spec against
the service-class policy (the realm steward's installed policy file)
and either approves or refuses.

This is narrower than a citizen's credential, which is implicitly
broad ("you can do citizen-things"). Service principals are explicit.

## Where it does NOT live

Three patterns hecate-services explicitly avoids:

1. **No user-bound services.** A `hecate-rag` running on Alice's
   laptop "for Alice" is wrong. Move it onto a realm-owned
   infrastructure node and let Alice consult it across the mesh.
2. **No anonymity / self-rooted leaves.** Every service principal
   chains back to a realm root. No Pubky-style ungoverned leaves.
   See `memory/feedback_no_anonymity_only_sovereignty`.
3. **No shared "node identity" for multiple services on the same
   box.** Each service on each node has its own principal, even if
   three of them live on the same beam node. Loose authz is worse
   than a few extra keypairs.

## v1 vs v2

| | v1 (now) | v2 (when policy + UCAN delegation land) |
|--|----------|-----------------------------------------|
| Credential type | Realm-signed long-lived cert | Short-lived UCAN with explicit attenuation |
| Provisioning | `hecate-realm` admin tool, manual or scripted | `hecate-realm` exposes a `/api/v1/services/provision` endpoint; gitops reconciler calls it |
| Rotation | Manual reprovision | Auto-rotate before expiry |
| Revocation | Edit realm trust file + restart service | Realm publishes revocation list to mesh |

Both versions live behind `hecate_om_identity`. Consumers don't
notice the swap.

## Trigger to do v2

When the realm onboards its **first non-Tienen service node** — a
relay-box rented in another EU jurisdiction, or a node contributed
by a cooperative member. At that point we want machine-issued
service credentials, not a hand-edited trust file. Until then v1
is fine.
