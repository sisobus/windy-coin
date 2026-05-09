# Phase 3 Plan — successor minters

> **Status:** design sketch. None of this is built. Implementation is
> blocked on the Phase 3.2 external audit of the existing Phase 1 +
> Phase 2 contracts. This document is what we'll point a future
> auditor (and a future maintainer) at when those follow-up minters
> ship.

## Why successor minters at all

`Windy.sol` is permanent — supply cap, role gating, burn behaviour
all live there forever. The mining policy in
[`ZkExecutionMinterV2.sol`](../contracts/src/ZkExecutionMinterV2.sol)
is *one* implementation of "what counts as a successful Risc Zero
proof of windy execution"; there will be more. The phrase
"plug-in minter" is the design contract:

- A new minter is a fresh contract with its own per-mint logic.
- The multisig admin grants it `MINTER_ROLE` on `Windy`.
- Optionally, the multisig revokes `MINTER_ROLE` from the previous
  minter (or leaves it live if both should pay).
- `Windy.sol` itself is not redeployed and not upgraded.

The successor candidates below are independently shippable. They can
also be composed (run side by side, share `consumedNonce` /
`consumedProgram` mappings, etc.); §4 covers composition.

## 1. Halving minter

### Motivation

`Bronze 0.1 / Silver 1 / Gold 10` is a flat reward curve. Bitcoin's
halving ramps issuance down over time so early miners are rewarded
disproportionately while the cap stays intact. We can do the same on
top of `ZkExecutionMinterV2` without changing the score formula or
the eligibility gate.

### Mechanism (sketch)

`ZkExecutionMinterV2Halving` inherits the V2 logic and overrides only
the reward lookup:

```solidity
function _rewardForTier(Tier tier) internal view returns (uint256) {
    uint256 supply = WNDY.totalSupply();
    uint256 epoch = supply / HALVING_INTERVAL; // e.g. 1_000_000 WNDY per epoch
    uint256 base;
    if (tier == Tier.Bronze) base = REWARD_BRONZE;
    else if (tier == Tier.Silver) base = REWARD_SILVER;
    else base = REWARD_GOLD;
    return base >> epoch;        // halve once per filled epoch
}
```

`HALVING_INTERVAL` is an immutable constructor arg; an epoch length
expressed in *WNDY base units* of `totalSupply` (i.e. supply-driven,
not block-driven). A 1M-WNDY interval gives 21 epochs across the cap.

### Open design choices

- **Supply-driven vs block-driven epochs.** Supply-driven is
  fairer (predictable real reward per WNDY minted regardless of
  network activity); block-driven matches Bitcoin (the simulated
  scarcity is real-time). Recommend supply-driven for an L2.
- **Halving floor.** `base >> epoch` truncates to zero past 60 epochs
  (for `1e19`). A floor of "1 wei reward" prevents a silent
  zero-reward state past the floor — but with a 1M interval and
  21M cap we hit the cap before the floor matters.
- **Composition with V2.** Either V2 retires when halving deploys
  (single source of issuance, simpler accounting) or both run for
  some overlap window with separate `consumedProgram` maps. Audit
  recommendation drives this.

### Migration runbook (assuming V2 retires)

```
1. multisig: deploy ZkExecutionMinterV2Halving
2. multisig: WNDY.grantRole(MINTER_ROLE, halving)
3. multisig: WNDY.revokeRole(MINTER_ROLE, V2)
4. multisig: ZkExecutionMinterV2.pause()
5. (optional) re-verify on Basescan, update README live-contracts table
```

Same shape as the V1 → V2 migration; same `MigrateAdmin` script can
be templated for it.

## 2. Known-algorithm bonus minter

### Motivation

Some windy programs implement *culturally meaningful* algorithms —
Fibonacci, factorial, primes, sorting, the SPEC's ASCII-art
demoscene programs. The score formula doesn't see this; it grades on
abstract metric counters. A second, *independent* minter can pay an
additional reward when the proof's `outputHash` matches an admin-
curated allowlist.

This is the "famous algorithm bonus" the user proposed when we
designed Phase 2 — deferred because automatic detection is undecidable
(Rice's theorem) but **output-hash matching** is straightforward.

### Mechanism (sketch)

```solidity
contract KnownOutputBonusMinter is AccessControl, Pausable {
    IRiscZeroVerifier public immutable VERIFIER;
    Windy              public immutable WNDY;
    bytes32            public immutable IMAGE_ID;

    /// @notice Curated map: known outputHash → bonus in WNDY base units.
    mapping(bytes32 => uint256) public knownBonus;

    /// @notice Per-program bonus dedup. Same as V2's consumedProgram, but
    ///         a *separate* mapping so an honest program can claim both
    ///         the V2 tier reward AND the bonus exactly once each.
    mapping(bytes32 => bool) public consumedBonus;

    function setKnownBonus(bytes32 outputHash, uint256 amount)
        external onlyRole(CURATOR_ROLE)
    {
        knownBonus[outputHash] = amount;
        emit KnownBonusSet(outputHash, amount);
    }

    function claimBonus(bytes calldata seal, bytes calldata journal) external whenNotPaused {
        bytes32 journalDigest = sha256(journal);
        VERIFIER.verify(seal, IMAGE_ID, journalDigest);

        WindyJournal memory j = abi.decode(journal, (WindyJournal));

        uint256 bonus = knownBonus[j.outputHash];
        require(bonus > 0, "no bonus registered");
        require(!consumedBonus[j.programHash], "bonus already claimed");

        consumedBonus[j.programHash] = true;
        WNDY.mint(j.recipient, bonus);
        emit BonusClaimed(j.recipient, j.programHash, j.outputHash, bonus);
    }
}
```

The miner submits the *same* `(seal, journal)` to V2 and to this
bonus minter — once each. V2 pays the tier reward. The bonus minter
pays the bonus if `outputHash` is on the allowlist. Both deduplicate
on `programHash`, but in their own private maps so they don't
interfere.

### Curator role

`CURATOR_ROLE` is the addresses (multisig or DAO) that may register
or update bonus entries. Initial entries are easy to seed from OEIS:

| Algorithm                          | First-N output (sha256)                       | Suggested bonus |
| ---------------------------------- | --------------------------------------------- | --------------- |
| Fibonacci first 10 (`0 1 1 2 3 5 8 13 21 34 `) | `0xc8337b3a…41185` (`fib.wnd`)        | `1.0 WNDY`      |
| Factorial 1!–10!                  | `0xb610a2b5…18aa4` (`factorial.wnd`)         | `1.0 WNDY`      |
| First 10 primes                    | (compute via `cargo run`)                     | `2.0 WNDY`      |
| First 10 squares                   | (compute)                                     | `0.5 WNDY`      |
| `Hello, World!` exact              | `0xdffd6021…2986f` (`hello.wnd`)             | `0` (already trivial) |

The bonus amount is admin-set. Anti-abuse: a bonus is consumed once
per `programHash`, so once any miner claims the Fibonacci bonus, the
canonical `fib.wnd` (and any byte-identical variant) cannot claim
again — but a *different* windy program that also outputs the
Fibonacci sequence is a fresh claim.

### Open design choices

- **Bonus-eligibility constraints.** Should a bonus require that the
  V2 tier mint also succeed? Right now they're independent. Coupling
  them ("only programs that V2 marked as Bronze+ can claim a bonus")
  prevents trivial bonus farming via tier-None proofs.
  Recommendation: require V2 to have already consumed the program;
  that's a single SLOAD against `V2.consumedProgram(programHash)`.
- **Allowlist updates.** Pre-launch curate aggressively, then pause
  curator-side mutations. Or rotate curator membership through a DAO
  — depends on community size.
- **Bounds on bonus amount.** A per-bonus cap (≤ Gold) keeps the
  curator from accidentally inflating supply faster than the policy
  intends. Add as `uint256 public immutable MAX_BONUS`.

## 3. Composition rules across the three minter generations

| Minter            | Reward source            | Dedup key              | Eligibility |
| ----------------- | ------------------------ | ---------------------- | ----------- |
| V2 (today)        | tier dispatch            | `consumedProgram` (its own) | visited∈[10,1500] + score gate |
| V2-Halving        | tier dispatch × 2^(-epoch) | same shape — `consumedProgram` (its own) | same |
| KnownOutputBonus  | curator-registered amount | `consumedBonus` (separate) | optional V2-claimed precondition |
| (Phase 4) NFT minter | NFT mint, no WNDY        | `consumedNFT` (separate) | matches V2-claimed program |

Three properties hold across compositions:

1. **WNDY supply ≤ 21M always.** Every minter calls
   `Windy.mint(recipient, amount)` and `Windy.mint` enforces the cap.
   If the cap is reached the next mint reverts; no minter can sneak
   past it.
2. **Per-mint dedup is local.** `V2.consumedProgram` and
   `BonusMinter.consumedBonus` don't share memory; one mint to V2
   and one bonus claim are *both* the canonical "this program has
   been recognized" entry. That's intentional — a program can pay
   exactly once *per minter*.
3. **Pause is per-minter.** Pausing the bonus minter doesn't pause
   V2, and vice versa. The multisig has independent kill switches.

## 4. Governance escalation path

The Phase 1.5 → Phase 2 → Phase 3 progression already implies a
governance maturation:

| Phase                | Admin                                  | Pauser            | Curator (Phase 3 bonus) |
| -------------------- | -------------------------------------- | ----------------- | ----------------------- |
| Phase 1.5 / 2 (testnet) | EOA                                  | EOA               | n/a                     |
| Phase 2 mainnet      | Safe multisig (2/3)                    | Safe multisig (1/3) | n/a                     |
| Phase 3 launch       | Safe multisig                          | Safe multisig     | Safe multisig            |
| Phase 4+ (DAO?)      | DAO timelock                           | DAO timelock      | DAO timelock             |

The token's `DEFAULT_ADMIN_ROLE` is also `renounceRole`-able once
Phase 3+ minter set is stable — at which point WNDY becomes truly
ungoverned at the token level (Bitcoin-shape final state). The
minter set frozen at that point is whatever ships before the
renounce.

## 5. What this document is *not*

- Not a binding promise that any of the above will ship. The Phase 2
  free-mint policy already meets the "fair launch token with
  meaningful proof-of-work" thesis; halving and bonuses are
  optional polish.
- Not an audit scope. Each minter, when implemented, is its own
  audit. The bonus minter especially needs adversarial review of
  the curator role and the dedup-vs-V2 interaction.
- Not in any way blocking mainnet launch. Phase 2 is enough to ship.

## 6. Sequencing

Once the audit closes:

```
Phase 3.2  audit  →  fixes  →  reaudit (if scope changed)
Phase 3.3  mainnet launch (current V2)
Phase 3.4  monitor + indexer + frontend (Phase 3.1 scaffolding)
Phase 3.5  ship halving minter (audit cycle)
Phase 3.6  ship known-output bonus minter (audit cycle)
Phase 4    NFT minter + windy-aria integration (separate effort)
```

Each minter ships independently; the WNDY cap and the multisig admin
shape stay invariant the whole way.
