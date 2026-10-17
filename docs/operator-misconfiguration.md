# Operator Misconfiguration Safeguards

> **Issue #1393.** Complements host/network fault injection
> (`scripts/failure-injection.sh`) with the class of failure where a human
> operator makes a plausible mistake in a *live operational command*.
> Guards: `scripts/lib/operator_guard.sh` · Suite:
> `tests/operator_safety/test_operator_misconfiguration.sh` (operational-safety
> tier, runs in the standard tier; no network or Stellar CLI needed).

## Method

For each scenario we asked: would the contract reject it, would existing tooling
catch it, or would it succeed silently with harm? Contract validation catches
wrong *types* of call but not "valid but wrong target" (e.g. rotating to a
real-but-wrong address). The scenarios below were **silent before this change**
for the shell tooling; each now has a guard that fires before any network tool
runs (exit code 2).

| ID | Scenario | Harm if silent | Guard | Wired into |
|----|----------|----------------|-------|-----------|
| S01–S02 | Rotate key to a contract id / truncated address | Admin/service locked out | G06 | helper (rotation flows) |
| S03 | Rotate key to the current address | False sense of rotation | G07 | helper |
| S04–S06 | Account address, truncated or mangled id as contract id | Upgrade/rollback hits wrong or no contract | G03/G04 | `rollback.sh`, `staging-deploy.sh` |
| S07 | Rehearsal pointed at mainnet | Test mutation on production | G01 | `rotate-keys-rehearsal.sh`, `staging-deploy.sh` |
| S08 | Typo in network name | Wrong network alias | G02 | `rollback.sh`, `staging-deploy.sh` |
| S09–S10 | Staging params on mainnet / production on testnet | Wrong environment config | G17 | helper |
| S11 | RPC endpoint from another network | Reads/writes wrong chain | G18 | helper |
| S12–S13 | Unresolved `<ADMIN>`, `null` from failed lookup | Command runs with junk identity | G08 | all three scripts |
| S14 | Newline/space pasted into identity | Different identity resolved | G09 | all three scripts |
| S15–S16 | Missing / non-WASM upgrade artefact | Bad upgrade proposal | G10/G11 | `rollback.sh`, `staging-deploy.sh` |
| S17 | Rollback to the WASM already deployed | No-op presented as rollback | G12 | helper |
| S18–S20 | TTL-extension wallet list empty / invalid / duplicated | Wrong wallet set extended, wasted fees | G13–G15 | helper |
| S21–S22 | Threshold > signers, or zero | Governance lockout / no protection | G16 | helper |
| S23 | Zero timelock on mainnet | Defeats time-lock security property | G19 | helper |
| S24–S25 | Mainnet action unattended / wrong confirm | Unreviewed mainnet change | G20 | `rollback.sh` (existing prompt) |

"helper" guards are available for any script to call; they are exercised by the
suite and are the required pattern for new operator commands. `rollback.sh`
already had a typed mainnet confirmation (S24–S25 lock that behaviour in).

## Running

```bash
bash tests/operator_safety/test_operator_misconfiguration.sh
```

## Runbook cross-references

- [`key-rotation-runbook.md`](key-rotation-runbook.md) — rotation targets are
  validated (G06/G07) and the rehearsal refuses mainnet (G01).
- [`ops-runbook.md`](ops-runbook.md) — rollback and staging deploy now refuse
  malformed ids, unknown networks and bad artefacts before acting.
