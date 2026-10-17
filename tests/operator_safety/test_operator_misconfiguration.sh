#!/usr/bin/env bash
# Operator-misconfiguration suite (issue #1393). Operational-safety tier.
# Each scenario feeds a plausible human mistake to a guard or to a real script
# and asserts it is refused (or, for the control cases, accepted).
# Catalogue: docs/operator-misconfiguration.md
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/operator_guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

G="G$(printf 'A%.0s' {1..55})"     # valid account address shape
G2="G$(printf 'B%.0s' {1..55})"
C="C$(printf 'A%.0s' {1..55})"      # valid contract id shape

refuse() { # name expected-guard-id cmd...
  local name="$1" id="$2"; shift 2
  local out; out="$("$@" 2>&1 >/dev/null)"; local rc=$?
  if [ $rc -ne 0 ] && [[ "$out" == *"GUARD[$id]"* || "$id" == "-" ]]; then
    PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name (rc=$rc out=$out)"; fi
}
accept() { # name cmd...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name (expected accept)"; fi
}

printf '\0asm\1\0\0\0' > "$TMP/a.wasm"; printf '\0asm\1\0\0\0' > "$TMP/b.wasm"
printf 'not wasm' > "$TMP/bad.wasm"; printf '\0asm\2\0\0\0' > "$TMP/c.wasm"
printf '%s\n%s\n' "$G" "$G2" > "$TMP/wallets.ok"
printf '%s\n%s\n' "$G" "$G" > "$TMP/wallets.dup"
printf '%s\nGSHORT\n' "$G" > "$TMP/wallets.bad"
: > "$TMP/wallets.empty"

# 1 key rotation to the wrong kind of address / typo
refuse "S01 rotate key to contract id instead of account" G06 guard_rotation_target "$G" "$C"
refuse "S02 rotate key to truncated address"              G06 guard_rotation_target "$G" "${G:0:20}"
refuse "S03 rotate key to the current address (no-op)"    G07 guard_rotation_target "$G" "$G"
# 2 target wrong
refuse "S04 account address passed as contract id"        G03 guard_contract_id "$G"
refuse "S05 truncated contract id"                        G04 guard_contract_id "${C:0:30}"
refuse "S06 lowercase (mangled) contract id"              G04 guard_contract_id "$(echo "$C" | tr A-Z a-z)"
# 3 network
refuse "S07 rehearsal pointed at mainnet"                 G01 guard_network mainnet testnet futurenet
refuse "S08 typo'd network name"                          G02 guard_network testnett testnet futurenet mainnet
refuse "S09 staging params applied to mainnet"            G17 guard_env_matches_network staging mainnet
refuse "S10 production params applied to testnet"        G17 guard_env_matches_network production testnet
refuse "S11 testnet RPC with mainnet selected"            G18 guard_rpc_matches_network https://soroban-testnet.stellar.org mainnet
# 4 values
refuse "S12 unresolved <ADMIN> placeholder"               G08 guard_not_placeholder "<ADMIN>" admin
refuse "S13 literal 'null' from a failed jq lookup"       G08 guard_not_placeholder null contract-id
refuse "S14 trailing newline pasted into identity"        G09 guard_no_whitespace $'admin\n' identity
# 5 artefacts
refuse "S15 WASM path missing"                            G10 guard_wasm_file "$TMP/missing.wasm"
refuse "S16 non-WASM file given as upgrade artefact"      G11 guard_wasm_file "$TMP/bad.wasm"
refuse "S17 rollback to the same WASM as current"         G12 guard_distinct_files "$TMP/a.wasm" "$TMP/b.wasm"
# 6 TTL extension wallet sets
refuse "S18 TTL wallet list empty"                        G13 guard_wallet_list "$TMP/wallets.empty"
refuse "S19 TTL wallet list has an invalid wallet"        G14 guard_wallet_list "$TMP/wallets.bad"
refuse "S20 TTL wallet list has duplicates"               G15 guard_wallet_list "$TMP/wallets.dup"
# 7 governance parameters
refuse "S21 threshold above signer count"                 G16 guard_threshold 4 3
refuse "S22 zero threshold"                               G16 guard_threshold 0 3
refuse "S23 zero timelock on mainnet"                     G19 guard_timelock mainnet 0
refuse "S24 mainnet action with --non-interactive"        G20 guard_confirm mainnet rollback-mainnet true
refuse "S25 mainnet action with wrong confirmation"       G20 guard_confirm mainnet rollback-mainnet false nope

# Controls: correct inputs are not blocked.
accept "C01 valid rotation"            guard_rotation_target "$G" "$G2"
accept "C02 valid contract id"         guard_contract_id "$C"
accept "C03 testnet rehearsal"         guard_network testnet testnet futurenet
accept "C04 distinct WASMs"            guard_distinct_files "$TMP/a.wasm" "$TMP/c.wasm"
accept "C05 good wallet list"          guard_wallet_list "$TMP/wallets.ok"
accept "C06 correct mainnet confirm"   guard_confirm mainnet rollback-mainnet false rollback-mainnet

# Real scripts refuse before touching any network tool (exit 2 = guard).
script() { # name expected-rc cmd...
  local name="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  if [ $rc -eq "$want" ]; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name (rc=$rc want=$want)"; fi
}
script "R01 rollback.sh rejects account address as contract" 2 \
  bash "$ROOT/scripts/rollback.sh" --dry-run testnet adm "$G" "$TMP/a.wasm"
script "R02 rollback.sh rejects non-WASM previous artefact"   2 \
  bash "$ROOT/scripts/rollback.sh" --dry-run testnet adm "$C" "$TMP/bad.wasm"
script "R03 rollback.sh rejects unknown network"              2 \
  bash "$ROOT/scripts/rollback.sh" --dry-run mainet adm "$C" "$TMP/a.wasm"
script "R04 staging-deploy.sh rejects mainnet"                2 \
  bash "$ROOT/scripts/staging-deploy.sh" --dry-run mainnet "$C" adm "$TMP/a.wasm" "$TMP/s.json"
script "R05 staging-deploy.sh rejects truncated contract id"  2 \
  bash "$ROOT/scripts/staging-deploy.sh" --dry-run testnet "${C:0:10}" adm "$TMP/a.wasm" "$TMP/s.json"
script "R06 rotate-keys-rehearsal.sh rejects mainnet"         2 \
  env NETWORK=mainnet bash "$ROOT/scripts/rotate-keys-rehearsal.sh" --dry-run
script "R07 rotate-keys-rehearsal.sh rejects placeholder id"  2 \
  env ADMIN_IDENTITY='<ADMIN>' bash "$ROOT/scripts/rotate-keys-rehearsal.sh" --dry-run

echo "operator-misconfiguration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
