# windy-mine

End-to-end miner CLI for the **WNDY** ([windy-coin](https://github.com/sisobus/windy-coin)) token on Base mainnet.

```bash
cargo install windy-mine

# real mint (5–10 min, needs Docker for Groth16 wrap)
windy-mine programs/foo.wnd

# score-only (~seconds, no Docker, no tx)
windy-mine programs/foo.wnd --dry-run
```

Also installs as a plugin for the [`windy`](https://crates.io/crates/windy-lang) CLI ≥ v2.3.0 — typing `windy mine programs/foo.wnd` is identical.

## What it does

`windy-mine programs/foo.wnd`:

1. Runs the windy-lang program inside a Risc Zero zkVM guest.
2. Wraps the resulting STARK in a Groth16 receipt (via local Docker prover).
3. Predicts the score by calling `ZkExecutionMinterV2.computeScore` (free, on-chain).
4. Calls `cast send` to submit `mint(seal, journal)` to mainnet, signing with a Foundry keystore.

`--dry-run` short-circuits after step 1 — no Docker, no proof, no tx — and just prints the predicted tier:

```
score:    87.780  (scoreX1000 = 87780)
tier:     3 → Gold
reward:   10.0 WNDY
```

## Configuration

Sensible Base mainnet defaults are baked in. Common overrides:

| Flag | Default |
|------|---------|
| `--dry-run` | (off) |
| `--account <name>` | `deployer-mainnet` |
| `--recipient 0x...` | derived from `--account` via `cast wallet address` |
| `--rpc <url>` | `https://mainnet.base.org` |
| `--minter 0x...` | `0xc566ab14616662ae92095a72a8cc23bf62b6ff02` |
| `--wndy 0x...` | `0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca` |
| `--nonce 0x...` | random |
| `--max-steps N` | `100000` |

## Prereqs

- [Foundry](https://book.getfoundry.sh) (`cast` is shelled out to for chain calls + keystore signing).
- A Foundry keystore (`cast wallet import deployer-mainnet --interactive`) — only needed for real mint, not `--dry-run`.
- Docker Desktop — only needed for real mint (Groth16 wrap container).

The Risc Zero guest ELF and its `IMAGE_ID` are baked into this binary at compile time. The pinned `IMAGE_ID` matches what the live mainnet minter expects:

`0xb78810f2e9557907cf9865797240661414e8102326cfdd8d8bc7879d58ca57cb`

## Eligibility

The on-chain mint reverts before scoring if any of these fail. `--dry-run` warns about them up-front:

- `10 ≤ visitedCells ≤ 1500`
- score ≥ 10 (= Bronze floor)
- this `program_hash` has not been minted before (first-claim, permanent)
- this `nonce` has not been used before

See [`docs/MINING-GUIDE.md`](https://github.com/sisobus/windy-coin/blob/master/docs/MINING-GUIDE.md) and [`docs/PHASE-2-MINING.md`](https://github.com/sisobus/windy-coin/blob/master/docs/PHASE-2-MINING.md) in the windy-coin repo for the full scoring policy.

## License

MIT.
