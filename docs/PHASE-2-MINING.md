# Phase 2 Mining Policy — Design Spec v1.0

> **Status:** design. Not yet implemented. The Phase 1.5 minter live on Base
> Sepolia is the *free-mint* contract that this policy is intended to replace.
>
> **Implementation deferred to a follow-up session.** This document is the
> source of truth for what gets built.

## 1. Goal

Three requirements drive the policy:

1. **Encourage lots of working windy code.** A successful proof of any
   sufficiently meaningful windy execution should mint WNDY.
2. **Reward harder code more.** A program that exercises the language's
   hard-to-simulate features (multi-IP, self-modification, branching, speed
   changes) should mint more than a program that only walks a straight line.
3. **Encourage *new* programs, not the reuse of one good program.** Each
   distinct windy source mints at most once across the entire chain
   lifetime. The first miner to submit a given `program_hash` claims the
   reward; subsequent submissions of the byte-identical source revert.
   This turns mining into a search for previously-unsolved programs, not
   a loop that re-submits a known-good proof forever.

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
exitCode, steps)`. Phase 2 adds **eight** more fields, all measured by the
guest at execution time and committed alongside the existing six:

| Field              | Type      | Source                                                        |
| ------------------ | --------- | ------------------------------------------------------------- |
| `hardOpcodeBitmap` | `uint16`  | bit `i` set ↔ at least one execute of the i-th hard opcode    |
| `maxAliveIps`      | `uint64`  | peak `vm.ips.len()` over the run                              |
| `spawnedIps`       | `uint64`  | total `t` invocations (including from spawned IPs)            |
| `gridWrites`       | `uint64`  | total `p` invocations                                         |
| `branchCount`      | `uint64`  | total `_` + `\|` + `~` invocations                            |
| `visitedCells`     | `uint64`  | distinct `(x, y)` cells some IP actually executed at — the **trace-truth code size** |
| `effectiveCells`   | `uint32`  | non-NOP cells in the parsed source grid (advisory)            |
| `totalGridCells`   | `uint32`  | width × height of the bounding box of the parsed grid (advisory) |

`hardOpcodeBitmap` bit assignments (low bit first): `t`, `p`, `g`, `_`, `|`,
`≫`, `≪`, `~`, `#`, `"`. Bits 10–15 are reserved.

These are all *dynamic* counters, populated by the windy interpreter inside
the zkVM guest. The host never measures them — only the guest's measurements
are bound into the proof. A liar gets caught at `verify()` time.

`visitedCells` is the metric that replaces "how big is this program?" duty
in the policy below. The earlier draft used `effectiveCells` (the parse-time
count of non-NOP cells), which got inflated by punctuation in sisobus
signatures and comment tables — `puzzle_hard.wnd` reads as 17 cells of real
code plus a 770-cell write-up, and `effectiveCells` couldn't distinguish
them. `visitedCells` only counts cells the IP actually ran on, so commented
rows and unreachable signatures never count.

`effectiveCells` and `totalGridCells` are kept on the journal as advisory
metrics: they expose the static layout (their ratio is a "density" hint
useful to off-chain analytics), but the on-chain policy does not gate on
them. A miner who packs their source as densely as possible and a miner
who pads their source with a sisobus banner are graded identically, as
long as the IP traces the same number of cells.

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
    uint64  visitedCells;
    uint32  effectiveCells;
    uint32  totalGridCells;
}
// ABI-encoded: 14 head slots × 32 bytes = 448 bytes (Phase 1: 192 bytes)
```

## 4. Eligibility gate

Before computing a score, the contract enforces three **hard cuts**. A
journal that fails any of them reverts the transaction — no Bronze, no
consolation, no state change.

```
require !consumedProgram[programHash]                  // first-claim only
require !consumedNonce[nonce]                          // standard replay protection
require 10 ≤ visitedCells ≤ 1500                       // honest-program size
```

The `consumedProgram` cut implements goal 3 directly: a `program_hash` is
consumed exactly once, by whoever wins the race to land its first
successful `mint(...)`. Two miners independently arriving at the same
windy source race to the chain — exactly one mint, even though they each
generated a valid proof. (A losing miner pays gas but no token; the
losing transaction reverts before any state writes.)

The `visitedCells` cut excludes both noise (< 10 cells executed —
trivial programs like `@`) and oversized programs (> 1500 cells, where
the policy stops being calibrated; that range is reserved for Phase 3+).
Because `visitedCells` only counts cells the IP actually traced, a
miner can put as much sisobus signature / commentary / dead code as
they like into the source — none of it inflates the count, and none of
it shrinks the count either.

> **No density gate.** Earlier drafts of this spec gated on
> `effectiveCells / totalGridCells ≥ 0.20` to block huge-grid spam
> ("100×100 cells with ten hard opcodes scattered, IP visits the
> ten"). With `visitedCells` as the eligibility metric, that scenario
> already loses on its own merits: a `visitedCells = 10` proof
> produces a tiny score (because all the *other* metrics are zero too)
> and the multiplicative diversity factor in §5 then multiplies that
> tiny core by ≤ ~3 — not enough to clear Bronze. The density gate
> would be redundant, so we drop it.

## 5. Score formula

```
diversityWeighted =
      8·t  + 8·p  + 6·g
    + 4·_  + 4·|
    + 3·≫  + 3·≪
    + 2·~  + 2·#
    + 1·"
                                   (max 41 if all ten flags set)

spawnedDensity = spawnedIps / max(visitedCells, 1)
spawnedScore   = (spawnedDensity > 0.5)
                   ? 0
                   : min(spawnedIps, 20) × 1.5      (max 30)

core = ⌊log2(max(maxAliveIps, 1))⌋ × 10            (1→0, 2→10, 4→20, 16→40, 1024→100)
     + spawnedScore
     + min(gridWrites,  100) × 0.3                 (max 30)
     + min(branchCount, 100) × 0.2                 (max 20)

# diversityWeighted does not contribute additively; it scales `core`.
# Range: 1.00 (no hard opcodes) to ~3.05 (all ten — only achievable
# from a non-zero core, since pure diversity with no other metric
# multiplies a zero core to zero).
diversityFactor = 1 + diversityWeighted × 5 / 100   (integer math: ×5 then ÷100)

score = core × diversityFactor
```

**Why diversity is multiplicative, not additive.** The earlier draft
treated `diversityWeighted` as a fifth additive bucket. That made
"huge-grid spam with all ten hard opcodes scattered, IP visits the
ten" reach Silver on diversity alone (41 points) — which is exactly
the wrong outcome. With diversity as a multiplier, that same
adversary's `core` is zero (no real multi-IP, no real grid writes,
no real branches), and `0 × 3.05` is still `0`. Real programs hit
both axes — they spawn IPs *and* write to grid memory *and* branch *and*
use a few hard opcodes — so they're rewarded for the combination, not
for any one metric in isolation.

**Why the t-spam guard is keyed on `visitedCells`.** A program of the
shape `tttt…@` (a hundred SPLITs in a row) has high `spawnedIps` but
also high `visitedCells` — every cell of the chain gets executed, so
the ratio `spawned / visited` ≈ 1.0, well above the 0.5 cutoff. The
spawned bonus is zeroed and the only contribution left to `core` is
`log2(max_alive_ips) × 10`, which is bounded by how many IPs survive
the collision-merge tick. A real timing puzzle like `puzzle_hard.wnd`
(3 spawns / 15 visited cells = 0.20 ratio) clears the cutoff and gets
the spawned bonus.

All four `core` summands are clamped at finite ceilings, so an
adversary cannot push the score arbitrarily high by inflating any one
metric. The realistic max for `core` is around 130 (40 + 30 + 30 + 20
+ slack), which a 3.05× diversity factor takes to around 396 —
comfortably above the Gold floor without being a runaway.

## 6. Tier dispatch

| Score          | Tier      | Reward                                       | On-chain effect                       |
| -------------- | --------- | -------------------------------------------- | ------------------------------------- |
| `< 10`         | None      | n/a                                          | `mint()` reverts ("score below floor") |
| `[10, 30)`     | Bronze    | `0.1 WNDY` (`1e17` base units)               | mint succeeds                         |
| `[30, 70)`     | Silver    | `1 WNDY`   (`1e18` base units)               | mint succeeds                         |
| `≥ 70`         | Gold      | `10 WNDY`  (`1e19` base units, per-proof cap) | mint succeeds                         |

Sub-Bronze scores **revert** instead of minting zero — this preserves the
miner's `nonce` and `program_hash` for a subsequent attempt at a higher
score (e.g., the same algorithm rewritten more densely, since `program_hash`
changes the moment a single byte changes). The contract never writes
`consumedProgram[programHash] = true` for a sub-Bronze submission.

The 0.1 / 1 / 10 spread (10× per tier) means a single Gold mint is worth
exactly 100 Bronze mints — a strong gradient, but the per-proof cap of 10
WNDY keeps the 21M supply curve realistic.

## 7. Sample programs against this policy

Measured against `windy-lang` v2.2.1 with the `metrics` feature on,
running each program through the windy-coin guest with seed 0 and
the default `--max-steps 100000`.

| Program             | visited | maxIPs | spawned | writes | branches | div_w | core  | factor | score    | tier    |
| ------------------- | ------: | -----: | ------: | -----: | -------: | ----: | ----: | -----: | -------: | ------- |
| `random.ts` output  |       ~ |      1 |       0 |      0 |        0 |     0 |   0.0 |   1.00 |    **0** | None    |
| `hello.wnd`         |      29 |      1 |       0 |      0 |        0 |     1 |   0.0 |   1.05 |    **0** | None    |
| `hello_winds.wnd`   |      30 |      1 |       0 |      0 |       14 |     7 |   2.8 |   1.35 |  **3.78** | None    |
| `sum_winds.wnd`     |      24 |      2 |       1 |      0 |        0 |     8 |  11.5 |   1.40 | **16.10** | Bronze  |
| `hi_windy.wnd`      |      49 |      2 |       1 |      0 |       10 |    15 |  13.5 |   1.75 | **23.62** | Bronze  |
| `fib.wnd`           |     100 |      1 |       0 |     33 |       10 |    18 |  11.9 |   1.90 | **22.61** | Bronze  |
| `factorial.wnd`     |     113 |      1 |       0 |     22 |       10 |    18 |   8.6 |   1.90 | **16.34** | Bronze  |
| `puzzle_hard.wnd`   |      15 |      4 |       3 |      0 |        0 |     8 |  24.5 |   1.40 | **34.30** | Silver  |
| `t`-spam (`tttt…@`) |     100 |     50 |     100 |      0 |        0 |     8 |  ~57  |   1.40 |    ~80   | Silver  |
| Grid-spam (100×100) |      10 |      1 |       0 |      0 |        0 |    41 |   0.0 |   3.05 |    **0** | None    |

`hello.wnd` and `random.ts` output both score zero (or near it) —
exactly the intended outcome. `puzzle_hard.wnd` lands at Silver,
matching its "genuinely hard timing-puzzle but not the absolute peak"
character. `fib.wnd` and `factorial.wnd` settle at Bronze: heavy
grid-memory work without the multi-IP boost.

The `t`-spam row is the policy's edge case. A program that's just
SPLITs in a line *does* land at Silver here — it has 50+ alive IPs and
that's what `core` rewards. We accept that: a windy program that puts
50 IPs onto the grid simultaneously is, in some real sense, doing more
work than `hello.wnd`. If a future operator finds that real spam
mining concentrates on this shape, the next minter version can either
gate `core` on `visitedCells / spawnedIps > 1` or replace `maxAliveIps`
with `(maxAliveIps − spawnedIps)` to disqualify pure SPLIT chains. For
now the simpler form ships.

The `Grid-spam` row is the case the eligibility gate previously dealt
with via a density check. With `visitedCells` as the eligibility
metric, the IP only visits 10 cells regardless of the surrounding
grid, so `core = 0` and the multiplicative diversity factor takes
zero to zero. No density gate needed.

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

Phase 2 ships in three sessions:

  - **Session A (done)** — bring the journal up to v2 and instrument
    the interpreter. windy-lang gets a `metrics` feature in v2.2.0 and
    a `visited_cells` counter in v2.2.1; circuit/core / circuit/guest
    / circuit/host carry the new 14-field journal end-to-end and run
    the seven sample programs at the score levels in §7.

  - **Session B (done)** — `ZkExecutionMinterV2.sol` + 25 Foundry
    tests live in `contracts/`. 100% line/branch/function coverage on
    the V2 contract; combined Foundry suite is 51 tests passing
    (15 Windy + 11 V1 + 25 V2). Slither finds zero issues.

  - **Session C** — deploy V2 to Base Sepolia, source-verify on
    Basescan, transfer `MINTER_ROLE` from the Phase 1.5 minter to V2,
    pause V1.

`Windy.sol` is untouched in all three.

### Session B contract checklist

`contracts/src/ZkExecutionMinterV2.sol` — same `Pausable` +
`AccessControl` shape as V1, plus:

  - the eligibility gate from §4 (including the new
    `consumedProgram[programHash]` mapping — first-claim-wins, plus
    the `10 ≤ visitedCells ≤ 1500` cut),
  - the multiplicative score formula from §5. All scalars are integer
    arithmetic in `uint256`: `0.3 → ×3 / 10`, `0.2 → ×2 / 10`,
    `1.5 → ×3 / 2`, `1 + diversity × 0.05 → 100 + diversity × 5`
    (apply by computing `core × (100 + diversityWeighted × 5) / 100`),
  - `log2_floor` via OZ `Math.log2(x, Math.Rounding.Floor)`,
  - tier dispatch from §6 with `REWARD_BRONZE / SILVER / GOLD`
    immutables; sub-Bronze reverts so neither `consumedNonce` nor
    `consumedProgram` is written,
  - `consumedNonce` carried over from V1 without change,
  - `consumedProgram` is new (`mapping(bytes32 => bool)`), read in
    the gate, written immediately before the external `WNDY.mint(...)`
    call,
  - `Minted` event extended to include the score and tier so off-chain
    indexers can compute the supply curve without re-running the
    formula.

`contracts/test/ZkExecutionMinterV2.t.sol` covers, at minimum:
  - each tier-boundary case (score 4 → None, 5 → Bronze, 24 → Bronze,
    25 → Silver, 49 → Silver, 50 → Gold) using `mockProve` to
    fabricate a journal at the requested score,
  - replay (same nonce) and dup-program (same programHash, fresh
    nonce) both revert,
  - `visitedCells = 9` and `visitedCells = 1501` both revert at the
    eligibility gate before scoring,
  - the `spawnedIps / visitedCells > 0.5` t-spam guard nukes only the
    spawned bonus, leaving `maxAliveIps`'s contribution intact,
  - missing `MINTER_ROLE` reverts the way V1 does, and reward-over-cap
    reverts via `Windy.MaxSupplyExceeded` the same way.

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
- **(removed)** *Per-program-hash deduplication is now part of the eligibility
  gate (§4) — see goal 3 in §1.* The earlier draft of this spec deferred
  it; that decision is reversed.
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
- **Race condition on first-claim.** Two miners that arrive at the
  byte-identical windy source race to land their `mint(...)` first; the
  loser's transaction reverts and they pay gas without minting. This is
  a feature for goal 3 ("encourage new programs") but worth noting. We
  do *not* plan a commit-reveal scheme to mitigate this in Phase 2 —
  the simpler "first to land wins" model is fine for an experimental
  testnet phase, and any miner anxious about race losses can prove
  against a pre-broadcast nonce-only commitment scheme client-side
  before submitting.
