#!/usr/bin/env bash
# Operator-misconfiguration guards (issue #1393).
#
# Pure-bash validators that catch plausible human mistakes before an
# operational script touches a network. Each guard prints "GUARD[<id>]: ..." to
# stderr and returns 1 on a bad input. Source this file; it has no side effects.
# Scenario catalogue: docs/operator-misconfiguration.md

_guard_fail() { echo "GUARD[$1]: $2" >&2; return 1; }

# G01/G02: unknown network, or a network the script must never run against.
# Usage: guard_network <network> <allowed...>
guard_network() {
  local n="$1"; shift
  local a
  for a in "$@"; do [ "$n" = "$a" ] && return 0; done
  if [ "$n" = "mainnet" ]; then
    _guard_fail G01 "network 'mainnet' is not permitted for this command (allowed: $*)"
  else
    _guard_fail G02 "unknown network '$n' (allowed: $*)"
  fi
}

# G03/G04/G05: contract id must be a C-strkey (not an account G..., not truncated).
guard_contract_id() {
  local id="$1"
  case "$id" in
    G*) _guard_fail G03 "'$id' is an account address, not a contract id (C...)"; return 1 ;;
  esac
  [[ "$id" =~ ^C[A-Z2-7]{55}$ ]] || _guard_fail G04 "malformed contract id '$id' (expected C + 55 base32 chars)"
}

# G06: an account address must be a G-strkey (not a contract id, not truncated).
guard_account_address() {
  [[ "$1" =~ ^G[A-Z2-7]{55}$ ]] || _guard_fail G06 "malformed account address '$1' (expected G + 55 base32 chars)"
}

# G07: rotating a key to the identical address is a silent no-op that looks like success.
guard_rotation_target() {
  local old="$1" new="$2"
  guard_account_address "$new" || return 1
  [ "$old" != "$new" ] || _guard_fail G07 "new address equals the current address; nothing would rotate"
}

# G08: unresolved template/placeholder values must never reach a live command.
guard_not_placeholder() {
  case "$1" in
    ""|"<"*">"|*PLACEHOLDER*|null|undefined|TODO|changeme)
      _guard_fail G08 "${2:-value} is empty or an unresolved placeholder ('$1')" ;;
  esac
}

# G09: stray whitespace/newlines from copy-paste silently produce a different identity.
guard_no_whitespace() {
  case "$1" in
    *[[:space:]]*) _guard_fail G09 "${2:-value} contains whitespace: '$1'" ;;
  esac
}

# G10/G11: WASM artefact must exist and be a real WASM binary.
guard_wasm_file() {
  [ -f "$1" ] || { _guard_fail G10 "WASM file not found: $1"; return 1; }
  [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = "0061736d" ] ||
    _guard_fail G11 "$1 is not a WASM binary (bad magic)"
}

# G12: rolling back to the WASM that is already the target is a no-op.
guard_distinct_files() {
  if cmp -s "$1" "$2"; then _guard_fail G12 "$1 and $2 are byte-identical"; fi
}

# G13/G14/G15: wallet list for TTL extension: non-empty, valid, no duplicates.
guard_wallet_list() {
  local f="$1" addr
  [ -s "$f" ] || { _guard_fail G13 "wallet list '$f' is missing or empty"; return 1; }
  while IFS= read -r addr; do
    [ -z "$addr" ] && continue
    guard_account_address "$addr" || { _guard_fail G14 "invalid wallet in '$f'"; return 1; }
  done < "$f"
  if [ -n "$(grep -v '^$' "$f" | sort | uniq -d)" ]; then
    _guard_fail G15 "duplicate wallets in '$f'"
  fi
}

# G16: M-of-N threshold must satisfy 1 <= M <= N.
guard_threshold() {
  local m="$1" n="$2"
  [[ "$m" =~ ^[0-9]+$ && "$n" =~ ^[0-9]+$ ]] || { _guard_fail G16 "threshold/signers must be integers"; return 1; }
  { [ "$m" -ge 1 ] && [ "$m" -le "$n" ]; } || _guard_fail G16 "threshold $m is not within 1..$n signers"
}

# G17: a parameter file/profile tagged for one environment applied to another.
# Usage: guard_env_matches_network <declared-env: staging|production> <network>
guard_env_matches_network() {
  local env="$1" net="$2"
  case "$env:$net" in
    staging:mainnet) _guard_fail G17 "staging parameters targeted at mainnet" ;;
    production:testnet|production:futurenet) _guard_fail G17 "production parameters targeted at $net" ;;
    staging:testnet|staging:futurenet|production:mainnet) return 0 ;;
    *) _guard_fail G17 "unknown environment '$env'" ;;
  esac
}

# G18: RPC endpoint must belong to the selected network.
guard_rpc_matches_network() {
  local url="$1" net="$2"
  case "$net" in
    mainnet) if [[ "$url" == *testnet* || "$url" == *futurenet* ]]; then
      _guard_fail G18 "testnet RPC '$url' used with mainnet"; return 1; fi ;;
    testnet|futurenet) if [[ "$url" == *mainnet* ]]; then
      _guard_fail G18 "mainnet RPC '$url' used with $net"; return 1; fi ;;
  esac
}

# G19: a zero/very short timelock on mainnet defeats the time-lock security property.
guard_timelock() {
  local net="$1" secs="$2"
  if [ "$net" = "mainnet" ] && [ "$secs" -lt 3600 ]; then
    _guard_fail G19 "timelock ${secs}s is below the 3600s mainnet minimum"; return 1
  fi
}

# G20: typed confirmation for destructive mainnet actions; never satisfiable
# non-interactively. Usage: guard_confirm <network> <token> <non_interactive> [answer]
guard_confirm() {
  local net="$1" token="$2" noninteractive="$3" answer="${4-}"
  [ "$net" = "mainnet" ] || return 0
  [ "$noninteractive" = true ] && { _guard_fail G20 "refusing mainnet action in non-interactive mode"; return 1; }
  [ "$answer" = "$token" ] || _guard_fail G20 "confirmation token mismatch"
}
