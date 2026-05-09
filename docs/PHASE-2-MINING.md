# Phase 2 Mining Policy — Design Spec v1.0

> **Status:** design. Not yet implemented. The Phase 1.5 minter live on Base
> Sepolia is the *free-mint* contract that this policy is intended to replace.
>
> **Implementation deferred to a follow-up session.** This document is the
> source of truth for what gets built.

## 1. Goal

Two requirements drive the policy:

1. **Encourage lots of working windy code.** A successful proof of any
   sufficiently meaningful windy execution should mint WNDY.
2. **Reward harder code more.** A program that exercises the language's
   hard-to-simulate features (multi-IP, self-modification, branching, speed
   changes) should mint more than a program that only walks a straight line.

The reference `random.ts` generator (a TypeScript program that synthesizes
self-avoiding linear windy paths from a "safe" opcode pool) deliberately
*excludes* the language's hardest features. Anything `random.ts` can produce
must score zero. Anything that uses features `random.ts` can't simulate must
clear at least the bottom tier.

## 2. The hard-feature axis

`random.ts`'s exclusion list defines the difficulty axis exactly:

| Glyph | Name        | Why hard to simulate                          |
| ----- | ----------- | --------------------------------------------- |
| `t`   | SPLIT       | spawns concurrent IP — execution is no longer single-threaded |
| `p`   | GRID_PUT    | self-modifying source — runtime path can change underfoot |
| `g`   | GRID_GET    | reads (potentially mutated) source as data    |
| `_`   | IF_H        | direction depends on stack — control flow is dynamic |
| `\|`  | IF_V        | same, vertical                                |
| `≫`   | GUST        | speed changes skip cells; static path simulation drifts |
| `≪`   | CALM        | symmetric                                     |
| `~`   | TURBULENCE  | random direction (seed-determined but still 1-of-8) |
| `#`   | TRAMPOLINE  | skips next cell                               |
| `"`   | STR_MODE    | toggles cell decoding semantics               |

These ten opcodes form the **hard pool**. Counting how many of them a program
uses, with weights, is the diversity contribution to the score.

## 3. Inputs (added to journal)

The Phase 1 journal carries `(recipient, nonce, programHash, outputHash,
exitCode, steps)`. Phase 2 adds **seven** more fields, all measured by the
guest at execution time and committed alongside the existing six:

| Field              | Type      | Source                                                        |
| ------------------ | --------- | ------------------------------------------------------------- |
| `hardOpcodeBitmap` | `uint16`  | bit `i` set ↔ at least one execute of the i-th hard opcode    |
| `maxAliveIps`      | `uint64`  | peak `vm.ips.len()` over the run                              |
| `spawnedIps`       | `uint64`  | total `t` invocations (including from spawned IPs)            |
| `gridWrites`       | `uint64`  | total `p` invocations                                         |
| `branchCount`      | `uint64`  | total `_` + `\|` + `~` invocations                            |
| `effectiveCells`   | `uint32`  | non-NOP cells in the source grid (after parse)                |
| `totalGridCells`   | `uint32`  | width × height of the bounding box of the parsed grid         |

`hardOpcodeBitmap` bit assignments (low bit first): `t`, `p`, `g`, `_`, `|`,
`≫`, `≪`, `~`, `#`, `"`. Bits 10–15 are reserved.

These are all *dynamic* counters, populated by the windy interpreter inside
the zkVM guest. The host never measures them — only the guest's measurements
are bound into the proof. A liar gets caught at `verify()` time.

### Updated `WindyJournalSol`

```solidity
struct WindyJournalSol {
    address recipient;
    bytes32 nonce;
    bytes32 programHash;
    bytes32 outputHash;
    int32   exitCode;
    uint64  steps;
    uint16  hardOpcodeBitmap;
    uint64  maxAliveIps;
    uint64  spawnedIps;
    uint64  gridWrites;
    uint64  branchCount;
    uint32  effectiveCells;
    uint32  totalGridCells;
}
// ABI-encoded: 13 head slots × 32 bytes = 416 bytes (Phase 1: 192 bytes)
```

## 4. Eligibility gate

Before computing a score, the contract enforces two **hard cuts**. A journal
that fails either is worth zero — no Bronze, no consolation.

```
require 10 ≤ effectiveCells ≤ 300
require effectiveCells × 100 ≥ totalGridCells × 20    // density ≥ 0.20
```

The first cut excludes both noise (< 10 effective cells, e.g. `@`) and
oversized programs (> 300 cells, which we won't reward at all in Phase 2 —
they're a different design space).

The second cut prevents "huge grid + sprinkled hard opcodes" spam: a 100×100
grid that holds only 10 meaningful cells has density 0.001 and fails the gate
even though every other metric is fine.

## 5. Score formula

```
diversityWeighted =
      8·t  + 8·p  + 6·g
    + 4·_  + 4·|
    + 3·≫  + 3·≪
    + 2·~  + 2·#
    + 1·"
                                   (max 41 if all ten flags set)

spawnedDensity = spawnedIps / effectiveCells
spawnedScore   = (spawnedDensity > 0.5)
                   ? 0
                   : min(spawnedIps, 20) × 1.5      (max 30)

score = diversityWeighted
      + ⌊log2(max(maxAliveIps, 1))⌋ × 10           (1→0, 2→10, 4→20, 16→40, 1024→100)
      + spawnedScore
      + min(gridWrites,  100) × 0.3                (max 30)
      + min(branchCount, 100) × 0.2                (max 20)
```

The `spawnedDensity > 0.5` clause kills the "100 `t`s in a row" attack: any
program that spends more than half of its meaningful cells on SPLIT keeps
its `maxAliveIps` boost but loses the spawned-count bonus. A real timing
puzzle like `puzzle_hard.wnd` (3 spawns / 17 cells = 0.18 density) sails
through.

All four sums are clamped at finite ceilings, so an adversary cannot push
the score arbitrarily high by inflating any one metric. Realistic max is
about 161; reaching it requires *every* hard opcode plus heavy multi-IP
plus 100+ grid writes plus 100+ branches inside a 300-cell grid — at which
point we're glad to mint Gold for it.

## 6. Tier dispatch

| Score          | Tier      | Reward                                       |
| -------------- | --------- | -------------------------------------------- |
| `< 10`         | None      | `0 WNDY`                                     |
| `[10, 30)`     | Bronze    | `0.1 WNDY` (`1e17` base units)               |
| `[30, 70)`     | Silver    | `1 WNDY`   (`1e18` base units)               |
| `≥ 70`         | Gold      | `10 WNDY`  (`1e19` base units, per-proof cap) |

The 0.1 / 1 / 10 spread (10× per tier) means a single Gold mint is worth
exactly 100 Bronze mints — a strong gradient, but the per-proof cap of 10
WNDY keeps the 21M supply curve realistic.

## 7. Sample programs against this policy

Estimated; exact values land once the guest is instrumented.

| Program             | bytes | hard ops              | maxIPs | grid writes | branches | density | score (est.) | tier   |
| ------------------- | ----: | --------------------- | -----: | ----------: | -------: | ------: | -----------: | ------ |
| `random.ts` output  |     ~ | none                  |      1 |           0 |        0 |    1.00 |        **0** | None   |
| `hello.wnd`         |    30 | `"`                   |      1 |           0 |        0 |    1.00 |        **1** | None   |
| `hello_winds.wnd`   |   121 | `"`,`#`(?)            |      1 |           0 |        0 |    ~0.7 |       **3+** | None   |
| `puzzle_hard.wnd`   |   ~250|  `t`                  |      4 |           0 |        0 |    1.00 |     **32.5** | Silver |
| `fib.wnd`           |   277 | `g`,`p`,`_` or `\|`   |      1 |         ~10 |      ~10 |    ~0.7 |       **27** | Bronze |
| `factorial.wnd`     |  1031 | `g`,`p`,`_` or `\|`   |      1 |         ~50 |      ~10 |    ~0.7 |       **39** | Silver |
| `t`-spam (`tttt…@`) |   ~20 | `t`                   |    100 |           0 |        0 |    1.00 |       *gate* | None (spawnedDensity=1) |
| Grid-spam (100×100) | 10000 | all 10                |      1 |           1 |        1 |   0.001 |       *gate* | None (density 0.001) |

`hello.wnd` and `random.ts` output both score below 10 — exactly the
intended outcome. `puzzle_hard.wnd` lands at Silver, matching its
"genuinely hard but not the absolute peak" character. `factorial.wnd`
reaches Silver via grid-memory weight; `fib.wnd` is borderline Bronze
because it does the same kind of work in fewer steps.

## 8. Supply implications

Assume an empirical distribution of `99 % Bronze, 0.9 % Silver, 0.1 % Gold`
once Phase 2 is live. Average reward per accepted proof is then
`0.99·0.1 + 0.009·1 + 0.001·10 = 0.118 WNDY`. Filling the 21,000,000-WNDY
cap therefore needs roughly **178 million accepted proofs** — comfortably in
the multi-decade range without a halving schedule, and we keep the option of
introducing one later by deploying a successor minter that returns less per
tier.

A more Gold-skewed distribution (`90 / 9 / 1`) raises the average to
`0.28 WNDY` and shrinks supply life to ~75 million proofs — still healthy.

## 9. Implementation plan (next sessions)

The three changes that need to land together — guest measurement, the new
journal, and the new minter contract — all touch the proof binding, so they
ship as one coherent migration. Once it's broadcast, the deployer revokes
`MINTER_ROLE` from the Phase 1.5 minter and grants it to the V2 minter.
`Windy.sol` is untouched.

1. **`circuit/core`** — extend `WindyInput` (no behavior change) and
   replace `WindyJournalSol` with the v2 layout from §3. Update the
   ABI round-trip tests; the new journal is 416 bytes instead of 192.

2. **`circuit/guest`** — instrument the windy `Vm`. The cleanest path is a
   light fork of `windy-lang` (or a vendored copy under
   `circuit/guest/vendor/windy/`) that adds the seven counters as `Vm`
   fields and increments them at the existing opcode-dispatch sites. The
   guest's `main()` then reads them out alongside `vm.steps` and feeds
   the v2 `WindyJournalSol`.

3. **`contracts/src/ZkExecutionMinterV2.sol`** — same `Pausable` +
   `AccessControl` shape as the V1, plus:
   - the eligibility gate from §4,
   - the score formula from §5 (all integer arithmetic; the `0.3` /
     `0.2` / `1.5` scalars become `× 3 / 10`, `× 2 / 10`, `× 3 / 2` to
     stay in `uint256`),
   - `log2_floor` via OZ `Math.log2`,
   - tier dispatch from §6 with `REWARD_BRONZE / SILVER / GOLD`
     immutables,
   - `consumedNonce` carried over from V1 without change.

4. **`contracts/test/ZkExecutionMinterV2.t.sol`** — at minimum: each tier
   boundary, each eligibility-gate failure path, the `t`-spam guard,
   and a regression that tier-decisions are deterministic given the
   journal bytes.

5. **`contracts/script/DeployV2.s.sol`** — same shape as Deploy.s.sol
   plus the new `IMAGE_ID`. The `Windy` address is reused — we do not
   redeploy the token.

6. **Migration tx (manual, post-deploy)** — admin calls
   `wndy.revokeRole(MINTER_ROLE, oldMinter)` and
   `wndy.grantRole(MINTER_ROLE, newMinter)`. After this, only Phase 2
   mints are possible.

## 10. What's intentionally not in this policy

- **Output-hash difficulty (Bitcoin-style hash<TARGET).** Considered and
  rejected for Phase 2. Tier-based scoring already covers "harder code →
  more reward"; adding a probabilistic hash race on top mostly raises gas
  cost on both sides without changing the security story.
- **Per-recipient rate limiting.** Anti-spam is handled by score and
  eligibility, not by capping recipients. A relayer-friendly path stays
  simple this way.
- **Per-program-hash deduplication.** Same `program_hash` with a different
  `nonce` mints again — by design. Two real puzzles that happen to share a
  hash should both pay; novelty is not the metric being incentivized.
- **Static analysis on the source bytes.** The minter never sees the
  source. All grading is from the guest's runtime counters, which are
  bound into the proof.
- **Halving schedule.** Reserved for Phase 3+. The current `Bronze 0.1 /
  Silver 1 / Gold 10` flat curve will run for at least the first deployment
  cycle; a halving (or any other curve change) means deploying yet another
  minter and migrating `MINTER_ROLE`.

## 11. Open questions for implementation

- The exact `log2_floor` over `uint64` in Solidity — OZ's `Math.log2(x)` is
  rounded-up; we want floored. Check Solidity-side semantics during the
  V2 contract write.
- Whether to vendor `windy-lang` (full copy in `circuit/guest/vendor/`) vs
  publish a `windy-lang` PR that adds the metric counters upstream. The
  latter is cleaner long-term but blocks on review; vendoring keeps Phase 2
  unblocked.
- Whether the Phase 1.5 Sepolia deployment stays reachable forever or gets
  retired by a `Pausable.pause()` once Phase 2 is broadcast. Both are
  defensible; `pause()` is the explicit choice.
