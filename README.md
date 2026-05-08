# windy-coin

Proof-of-Windy: ZK-verified windy-lang execution mining for the **WNDY** token on Base.

> **Status (Phase 1.1):** ERC-20 contract + tests only. ZK execution minter, Risc Zero
> integration, and testnet deploy land in later phases. See [`CLAUDE.md`](./CLAUDE.md).

## Token spec (immutable)

| Field        | Value                                  |
| ------------ | -------------------------------------- |
| Name         | Windy                                  |
| Symbol       | WNDY                                   |
| Decimals     | 18                                     |
| Hard cap     | 21,000,000 WNDY (Bitcoin homage)       |
| Pre-mine     | 0% (fair launch)                       |
| Mint gating  | `MINTER_ROLE` (granted to minter only) |
| Burn         | Holders may burn their own balance     |

## Layout

```
contracts/         Foundry project
  src/Windy.sol    ERC-20 + Burnable + AccessControl, hard cap enforced
  test/Windy.t.sol Cap, role gating, burn, grant/revoke, renounce
  lib/             OpenZeppelin v5.4.0, forge-std (git submodules)
```

## Build & test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
cd contracts
forge build
forge test -vv
```

When cloning fresh, pull the lib submodules first:

```bash
git submodule update --init --recursive
```

## Trust model

- `Windy.sol` is intended to be deployed once and never replaced. New mint logic ships
  as separate `Minter` contracts that receive `MINTER_ROLE`.
- The hard cap is a `constant` in code — no admin path can change it.
- Initial admin holds only `DEFAULT_ADMIN_ROLE` (no `MINTER_ROLE`); cannot mint.
- Admin is expected to migrate to a multisig and eventually `renounceRole`.
