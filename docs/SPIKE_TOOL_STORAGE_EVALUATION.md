# Spike: Pluggable Storage Abstraction for Off-Chain Tooling

> **Issue #1397.** Recommendation: **do not build a pluggable storage-backend
> abstraction.** Extract only the duplicated durable-file and content-hash
> primitives (prototype: `tools/tool-store`).

## 1. Survey

There is **no indexer datastore in this repository**; every off-chain tool
persists flat JSON/JSONL files.

| Tool | Language | Persistence | Access pattern |
|------|----------|-------------|----------------|
| `tools/recovery` | Rust | JSON snapshots, plans, resume **checkpoint** (atomic write + `.bak`), SHA-256 plan/state roots | Whole-file read, whole-file replace; crash-safe resume matters |
| `tools/score-submitter` | Rust | In-memory + SHA-256 digests of canonical payloads | Hash-only; no storage |
| `tools/replay` | Rust | Reads JSONL traces/fixtures, prints evidence bundle with SHA-256 | Append-only input, stream scan, one-shot export |
| `tools/compliance-report` | Python | Reads JSONL events, writes canonical `report.json` + HTML with `content_hash` | Stream scan, one-shot export |
| `tools/invocation-fuzzer` | Rust | Plain `fs::write` of corpus seeds / minimized failures | Write-once files |
| `tools/schema-gen` | Rust | Generated schema files | Write-once, check-in |

## 2. What is actually duplicated

1. **Crash-safe replace** (write `.tmp`, fsync, park `.bak`, rename, roll back):
   implemented only in `recovery`. The fuzzer and recovery's own report outputs
   use non-atomic `fs::write`.
2. **`.bak` fallback read** for resumable state (`recovery`).
3. **SHA-256 hex of serialized JSON**: `recovery` (×2), `score-submitter`,
   `replay` (`format!("{:x}", …)`).

There is **no duplicated schema or migration logic**: no tool has a database
schema, and `schema_version` handling in `replay` and `ledgerlens-cli` is
format-specific. A "shared schema/migration layer" would abstract nothing real.

## 3. What stays bespoke, and why

- **`compliance-report`** — Python; a Rust crate cannot be shared, and its
  canonical-JSON/hash contract is specified independently (and must stay
  byte-stable for auditors). Cross-language unification would add an FFI/IPC
  boundary to save ~5 lines.
- **`replay`** — stream-scans append-only traces; a key/value or whole-file
  store is the wrong shape. Only its one-line hash helper is a candidate
  (not migrated in this prototype to keep the diff small).
- **`schema-gen`** — emits checked-in generated artifacts compared byte-for-byte
  in CI; atomicity is irrelevant.
- **Any query/index backend (SQLite, KV)** — rejected: no tool performs point
  lookups or range scans over persisted state, so a backend trait would be
  speculative.

## 4. Prototype

`tools/tool-store` exposes `write_bytes_atomic`, `backup_path`, `readable_path`,
`sha256_hex` (3 unit tests). Migrated:

- `tools/recovery`: removed its local `write_bytes_atomic`, `backup_path`,
  the `.bak` fallback expression (×2) and two `hex::encode(Sha256::digest(..))`
  call sites (`export_root`, `plan_hash`).
- `tools/score-submitter`: `hex_digest` now delegates to `sha256_hex`.

### Measurements (`git diff --numstat`)

| Item | Lines |
|------|-------|
| `recovery/src/main.rs` | +7 / −49 |
| `score-submitter/src/lib.rs` | +1 / −2 |
| New `tool-store/src/lib.rs` (incl. ~36 lines of tests) | +111 |
| **Net** | **+68 total, ≈ +32 excluding the new tests** |

Honest reading: line count does **not** drop — one implementation moved to a
shared crate. The value is risk, not LOC: one tested implementation of the
crash-safe replace (previously untested, in one binary), reusable by the
non-atomic `fs::write` sites without copying it a second time. Dependency
edges: `recovery` and `score-submitter` drop direct `sha2` (and `hex` stays for
signature handling).

### Behavior preservation

The moved functions are byte-for-byte the same code. Note that `recovery` and
`score-submitter` have **no existing automated tests** (`#[test]` count is 0), so
the existing suite cannot verify the migration; verification is that both crates
build and the new `tool-store` tests cover the moved functions. Adding tests to
the other tools was out of scope.

## 5. Recommendation

1. Keep `tool-store` as the single home for atomic-write + hash primitives.
2. Follow-up (separate PRs): switch the fuzzer's seed/failure writes and
   recovery's report outputs to `write_bytes_atomic`; point `replay` at
   `sha256_hex`; add integration tests for `recovery apply` resume.
3. Revisit a storage-backend trait only when a tool gains a real indexed
   datastore with point/range access; none exists today.
