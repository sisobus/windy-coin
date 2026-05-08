# windy-coin

Proof-of-Windy: ZK-verified windy-lang execution mining for the **WNDY** token on Base.

> **Status (Phase 1.2):** ERC-20 contract + tests, plus a hello-world Risc Zero zkVM
> skeleton (guest commits a fixed message, host generates and verifies a STARK receipt).
> The on-chain `ZkExecutionMinter`, the windy-lang interpreter inside the guest, and
> testnet deployment land in later phases. See [`CLAUDE.md`](./CLAUDE.md).

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

circuit/           Risc Zero zkVM workspace
  guest/           zkVM guest (currently a hello-world: env::commit_slice(b"hello, windy"))
  methods/         build glue: compiles the guest into ELF + image ID constants
  host/            host program: builds an executor env, proves, and verifies the receipt
```

## Build & test

### Foundry contracts

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

### Risc Zero circuit

Requires [`rzup`](https://dev.risczero.com/api/zkvm/install) (`curl -L https://risczero.com/install | bash && rzup install`) and a recent stable Rust toolchain.

> **Supported hosts:** macOS (aarch64 + x86_64) and x86_64 Linux. **aarch64 Linux is not supported** by Risc Zero — run the prover from one of the supported hosts.

```bash
cd circuit
cargo run --release -p host
```

The first build takes several minutes because it compiles the host-side Risc Zero stack and cross-compiles the guest with the `risc0` Rust toolchain. On success the host prints:

```
guest journal: hello, windy
receipt verified
```

To see prover progress, set `RUST_LOG=info`.

## Trust model

- `Windy.sol` is intended to be deployed once and never replaced. New mint logic ships
  as separate `Minter` contracts that receive `MINTER_ROLE`.
- The hard cap is a `constant` in code — no admin path can change it.
- Initial admin holds only `DEFAULT_ADMIN_ROLE` (no `MINTER_ROLE`); cannot mint.
- Admin is expected to migrate to a multisig and eventually `renounceRole`.
