# WNDY Tokenomics

A short, honest description of how the WNDY token's supply curve works
on Base. Keep this in sync with the on-chain reality — when a future
phase changes how WNDY enters circulation, this document changes too.

## 1. Token spec (immutable)

| Field            | Value                                        |
| ---------------- | -------------------------------------------- |
| Name / symbol    | Windy / WNDY                                 |
| Standard         | ERC-20 (also `ERC20Burnable`, `AccessControl`) |
| Chain            | Base (Ethereum L2). Sepolia today; mainnet pending external audit. |
| Decimals         | 18                                           |
| Hard cap         | **21,000,000 WNDY** — Bitcoin homage, declared `constant` so no admin can ever raise it. |
| Pre-mine         | **0**. Pure fair launch. No founder allocation, team allocation, treasury, or VC tranche. |
| Initial supply   | 0. Every token in circulation has been minted by a successful Risc Zero proof. |
| Burn             | Holders may burn their own balance via `ERC20Burnable.burn()`. Burned WNDY is gone — *no* re-mint. |

The `Windy` contract is intended to be deployed once and never replaced.
Successive minter contracts plug in by receiving `MINTER_ROLE`; the token
itself stays static across phase upgrades.

## 2. How a WNDY enters circulation

WNDY is mineable. There is no public sale, no airdrop, no liquidity-mining
program. The *only* way fresh WNDY ever appears is for a miner to:

1. Write a windy-lang program (or pick an unclaimed one).
2. Run it inside the Risc Zero zkVM via the project's host CLI.
3. Wrap the resulting STARK into a Groth16 proof (via the
   `risczero/risc0-groth16-prover` Docker image, multi-arch).
4. Submit `(seal, journal)` to `ZkExecutionMinterV2.mint(...)` on Base.
5. The minter verifies the proof, grades the journal against the policy
   in [`docs/PHASE-2-MINING.md`](./PHASE-2-MINING.md), and — if the score
   reaches a tier — calls `Windy.mint(recipient, tierReward)`.

The reward is fixed per tier:

| Tier   | Score range (`scoreX1000`)         | Human score     | Reward      |
| ------ | ---------------------------------- | --------------- | ----------- |
| None   | `< 10_000`                         | `< 10`          | revert (0)  |
| Bronze | `[10_000, 30_000)`                 | `[10, 30)`      | `0.1 WNDY`  |
| Silver | `[30_000, 70_000)`                 | `[30, 70)`      | `1.0 WNDY`  |
| Gold   | `≥ 70_000`                         | `≥ 70`          | `10.0 WNDY` |

Gold (10 WNDY) is the per-proof maximum. The 21M cap and the `MINTER_ROLE`
are the only chain-level safeguards against runaway issuance — the policy
itself is just the score formula plus the eligibility gate.

## 3. Distribution shape

Goal 3 of the policy ("encourage *new* programs, not the reuse of one
good one") is enforced by `consumedProgram[programHash]` first-claim
dedup. A given byte-for-byte windy source mints exactly once across the
chain's lifetime, no matter how many miners independently produce it.
Two consequences:

1. **Total supply ≤ 21,000,000 distinct windy programs being claimed.**
   To exhaust the cap entirely, the chain has to absorb at least 21M
   distinct working windy sources. That is a *lot* of original code; the
   cap is supply-limited not by inflation rate but by the universe of
   meaningful programs that can be authored.

2. **Distribution skew predicts curve length.** The realistic mix is
   heavy-Bronze (small but valid programs), thinner Silver (genuine
   problems with multi-IP / grid memory / branching), very thin Gold
   (programs that combine all of the above):

   | Mix (Bronze / Silver / Gold) | Avg reward | Proofs to fill 21M cap |
   | ---------------------------- | ---------: | ---------------------: |
   | `99 / 0.9 / 0.1` (conservative) | 0.118 WNDY |             ~178M proofs |
   | `95 / 4 / 1` (optimistic)       | 0.235 WNDY |              ~89M proofs |
   | `90 / 9 / 1` (heavy Silver)     | 0.28 WNDY  |              ~75M proofs |

   At the conservative end, the cap is meaningful for years. At the
   optimistic end, it would be exhausted faster — at which point the
   whole supply has accrued to whoever wrote the most original windy
   code, which is exactly the intent.

## 4. Phase 3+ evolution paths

The policy in V2 is intentionally simple. Three layered upgrades are
pre-thought and *not* yet implemented:

- **Halving schedule.** A successor minter can divide every tier reward
  by 2 once `totalSupply()` crosses a threshold. Implemented as: deploy
  V3, transfer `MINTER_ROLE` to it (and revoke from V2), V2 retired.
  Works because `MINTER_ROLE` is a moving target.
- **Known-algorithm bonus.** A separate minter (`KnownOutputBonusMinter`)
  reads the same `(seal, journal)` and pays an additional reward for
  proofs whose `outputHash` matches a curated allowlist of "famous
  algorithm outputs" (Fibonacci first-N, factorial first-N, primes,
  squares). Curated — admin (or DAO) registers `outputHash → bonus`.
- **Sonification NFT minter.** Phase 4 plan: integrate
  [windy-aria](https://github.com/sisobus/windy-aria) so a successful
  windy execution mints both WNDY *and* an NFT carrying the
  sonification of that program's IP path. Unrelated to the WNDY supply
  curve — runs on a separate ERC-721 contract with its own bonding
  rules.

None of these change WNDY's hard cap or its non-pre-mine status.

## 5. Token utility (current and reserved)

The minter pays in WNDY. What WNDY *does* — beyond being a fair-launch
record of "people who proved windy programs early" — is reserved for
later phases:

- **Reserved.** Governance over the curated bonus list (Phase 3 known-
  algorithm bonus minter) is the most plausible utility. Holders vote on
  which output hashes the bonus minter pays on.
- **Reserved.** `ERC20Burnable` is shipped from day one to leave the
  door open for deflationary mechanics in Phase 3+ — e.g. a
  challenge-puzzle minter that requires burning N WNDY to register a
  challenge, with the burn going against `totalSupply()`.
- **Not committed.** WNDY is *not* a security, has no claim on revenue,
  no governance over the token contract itself (which is immutable),
  and no buyback / fee redistribution. Holders own the supply share of
  whatever ends up minted — nothing more, nothing less.

## 6. Admin / role evolution

| Role                    | Today (Sepolia)                     | Mainnet plan                          |
| ----------------------- | ----------------------------------- | ------------------------------------- |
| `DEFAULT_ADMIN_ROLE` (Windy) | EOA `0xa37558…04af` (testnet key) | Multi-sig (Safe, ≥ 2/3 threshold). Eventually `renounceRole` once Phase 3+ minters are stable. |
| `MINTER_ROLE` (Windy)   | `ZkExecutionMinterV2` only          | Same shape. Phase 3 layered minters added by admin grant; previous minters revoked. |
| `DEFAULT_ADMIN_ROLE` (V2 minter) | EOA                          | Multi-sig. The minter has no upgrade path of its own — admin only manages `PAUSER_ROLE`. |
| `PAUSER_ROLE` (V2 minter) | EOA                              | Multi-sig (smaller threshold, e.g. 1/3) so any single signer can hit the kill switch fast. |

## 7. What this document is *not*

- Not legal advice. Holders should evaluate their own jurisdiction's
  treatment of an L2 token with this issuance shape.
- Not a roadmap commitment. The Phase 3+ paths in §4 are the planned
  direction; the timeline is whatever the maintainer can ship.
- Not a price prediction. WNDY has no market price as of this writing —
  the supply has only just left zero.

When in doubt, read the contracts:
[`Windy.sol`](../contracts/src/Windy.sol),
[`ZkExecutionMinterV2.sol`](../contracts/src/ZkExecutionMinterV2.sol),
and the [Phase 2 mining policy](./PHASE-2-MINING.md). They are the
canonical source of truth for everything above.
