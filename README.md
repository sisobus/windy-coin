# windy-coin

Proof-of-Windy: ZK-verified windy-lang execution mining for the **WNDY** token on Base.

> **Status (Phase 1.4a):** ERC-20 contract + tests, plus a Risc Zero zkVM circuit that
> runs the [windy-lang](https://crates.io/crates/windy-lang) v2.1.0 interpreter on a
> host-supplied program. The guest commits an **ABI-encoded** journal of `(recipient,
> nonce, programHash, outputHash, exitCode, steps)` — exactly the layout `ZkExecutionMinter`
> will `abi.decode`. The on-chain minter contract and testnet deployment follow.
> See [`CLAUDE.md`](./CLAUDE.md).

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
  core/            shared no_std crate:
                     - WindyInput (host→guest, risc0 serde)
                     - WindyJournalSol (guest→world, alloy sol! ABI struct)
  guest/           zkVM guest: reads WindyInput, runs the windy-lang interpreter,
                   commits the abi_encoded WindyJournalSol via env::commit_slice
  methods/         build glue: compiles the guest into ELF + image ID constants
  host/            CLI: takes --recipient + --nonce + program, proves, abi_decodes
                   the journal, verifies the receipt
  programs/        sample windy-lang programs (currently just `hello.wnd`)
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
# minimal: bundled hello.wnd, random nonce
cargo run --release -p host -- --recipient 0xYourEthAddress

# pin recipient + nonce + custom program
cargo run --release -p host -- \
  --recipient 0xYourEthAddress \
  --nonce 0x0000...0042 \
  --program-file programs/hello.wnd \
  --seed 42 --max-steps 50000

# feed stdin to a program that reads input
cargo run --release -p host -- \
  --recipient 0x... --program-file <path.wnd> --stdin-file <path.in>
```

`--recipient` is required (the address bound into the proof). `--nonce` defaults to a random 32 bytes; pin it for reproducibility. Other defaults: `--seed 0`, `--max-steps 100_000`, no stdin, bundled `programs/hello.wnd` when `--program-file` is omitted.

The first build takes several minutes because it compiles the host-side Risc Zero stack and cross-compiles the guest (windy-lang interpreter included) with the `risc0` Rust toolchain. On success the host prints:

```
guest journal:
  recipient:    0x0000000000000000000000000000000000000001
  nonce:        0x0000000000000000000000000000000000000000000000000000000000000042
  program_hash: 0x65e7d719acde91a75d7539d07ab34cc75e1a7aa711d7c76722ae5c601e798c96
  output_hash:  0xdffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f
  exit_code:    0 (Ok)
  steps:        29
  raw bytes:    192 (abi-encoded)
receipt verified
```

`output_hash` matches `sha256("Hello, World!")` — `hello.wnd` prints `Hello, World!` and halts. The `raw bytes` line is the ABI-encoded journal (6 fields × 32-byte slots) that an on-chain `ZkExecutionMinter` will `abi.decode`. To see prover progress, set `RUST_LOG=info`.

## Trust model

- `Windy.sol` is intended to be deployed once and never replaced. New mint logic ships
  as separate `Minter` contracts that receive `MINTER_ROLE`.
- The hard cap is a `constant` in code — no admin path can change it.
- Initial admin holds only `DEFAULT_ADMIN_ROLE` (no `MINTER_ROLE`); cannot mint.
- Admin is expected to migrate to a multisig and eventually `renounceRole`.
