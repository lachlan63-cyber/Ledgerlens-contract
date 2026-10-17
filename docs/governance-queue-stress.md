# Governance Timelock Queue — Sustained Single-Proposer Stress Test

> **Issue #1394.** Test: `contracts/ledgerlens-score/src/test_governance_queue_stress.rs`
> (standard tier, ~2 s).

## Policy under test

`propose_parameter_change` keeps at most `MAX_PENDING_PARAMETER_PROPOSALS`
(10) pending proposals. Expired entries (`proposed_at + 2 × time_lock`) are
pruned before the cap check. At the cap, new proposals are **rejected** with
`TooManyPendingParameterProposals`; nothing is evicted.

## What the test covers

- One authorized proposer submits 3× the cap per round for several rounds,
  through the public entry point (no storage seeding).
- Exactly the cap is accepted, every later attempt is rejected, and the queue
  length never exceeds the cap.
- Fairness: the pending list equals the accepted ids in submission order and
  every accepted proposal is still `Pending` (no silent eviction).
- Recovery: once the batch expires, the next proposal prunes it
  (`Expired`) and succeeds; ids stay strictly increasing across rounds.
- Cost at saturation (soroban test-env CPU instructions, measured 2026-10):

| Call at saturation | Measured | Budget asserted |
|---|---|---|
| `propose_parameter_change` (rejected) | ~374 k | 2 M |
| `get_pending_param_prop_ids` | ~260 k | 2 M |

## How this differs from existing tests

`test_parameter_governance.rs::test_maximum_pending_proposals_cap` and
`test_expired_full_pending_set_is_pruned_*` seed a full queue directly and
check one transition. This suite exercises *sustained* load via the real entry
point over repeated saturate → reject → expire → prune cycles, adds ordering /
no-eviction checks, and records cost at saturation. No contract bug or budget
violation was found.
