# windy-coin

Proof-of-Windy: ZK-verified windy-lang execution mining for the **WNDY** token on Base.

> **Status (Phase 1.3b):** ERC-20 contract + tests, plus a Risc Zero zkVM circuit that
> runs the [windy-lang](https://crates.io/crates/windy-lang) interpreter on a
> host-supplied windy program inside the guest and commits `(program_hash, output_hash,
> exit_code, steps)` to the receipt journal. The on-chain `ZkExecutionMinter` and
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
  guest/           zkVM guest: env::reads `WindyInput {program, seed, max_steps, stdin}`,
                   runs the windy-lang interpreter, and commits a `WindyJournal` of
                   {program_hash, output_hash, exit_code, steps}
  methods/         build glue: compiles the guest into ELF + image ID constants
  host/            CLI: loads a windy program from disk (or the bundled default),
                   writes it into ExecutorEnv, proves, decodes the journal, verifies
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
# bundled default — runs programs/hello.wnd
cargo run --release -p host

# any windy program with custom seed and step cap
cargo run --release -p host -- \
  --program-file programs/hello.wnd \
  --seed 42 \
  --max-steps 50000

# feed stdin to the program (e.g. for input-reading programs)
cargo run --release -p host -- \
  --program-file <path.wnd> --stdin-file <path.in>
```

CLI defaults: `--seed 0`, `--max-steps 100_000`, no stdin. Without `--program-file`, the bundled `programs/hello.wnd` is used.

The first build takes several minutes because it compiles the host-side Risc Zero stack and cross-compiles the guest (including the windy-lang interpreter) with the `risc0` Rust toolchain. On success the host prints:

```
guest journal:
  program_hash: 0x65e7d719acde91a75d7539d07ab34cc75e1a7aa711d7c76722ae5c601e798c96
  output_hash:  0xdffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f
  exit_code:    0 (Ok)
  steps:        29
receipt verified
```

`output_hash` matches `sha256("Hello, World!")` — `hello.wnd` prints `Hello, World!` and halts. To see prover progress, set `RUST_LOG=info`.

## Trust model

- `Windy.sol` is intended to be deployed once and never replaced. New mint logic ships
  as separate `Minter` contracts that receive `MINTER_ROLE`.
- The hard cap is a `constant` in code — no admin path can change it.
- Initial admin holds only `DEFAULT_ADMIN_ROLE` (no `MINTER_ROLE`); cannot mint.
- Admin is expected to migrate to a multisig and eventually `renounceRole`.
