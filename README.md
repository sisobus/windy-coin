# windy-coin

Proof-of-Windy: ZK-verified windy-lang execution mining for the **WNDY** token on Base.

> **Status (Phase 2):** ERC-20 contract + tests, a Risc Zero zkVM circuit running
> the [windy-lang](https://crates.io/crates/windy-lang) v2.2.1 interpreter (with the
> `metrics` feature for trace-truth code-size measurement), and the **tier-based
> `ZkExecutionMinterV2`** (Bronze 0.1 / Silver 1 / Gold 10 WNDY) live on Base Sepolia.
> The Phase 1 free-mint minter has had its `MINTER_ROLE` revoked and been paused — V2
> is the only path to a fresh WNDY. Audit baseline: 51 Foundry tests, 100% coverage on
> production contracts, Slither 0 findings. The first mint is blocked on Risc Zero's
> cloud prover (`bonsai.xyz` is down, Boundless successor still rolling out) — once a
> Groth16 prover is reachable, anyone can submit `mint(seal, journal)` via cast. See
> [`docs/PHASE-2-MINING.md`](./docs/PHASE-2-MINING.md) for the policy and
> [`CLAUDE.md`](./CLAUDE.md) for the broader project context.

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
  src/Windy.sol                  ERC-20 + Burnable + AccessControl, hard cap enforced
  src/ZkExecutionMinter.sol      Phase 1 free-mint minter (live on Sepolia, will be paused at Session C)
  src/ZkExecutionMinterV2.sol    Phase 2 tier-based minter: visited_cells gate + multiplicative
                                 diversity score + Bronze/Silver/Gold dispatch + program-hash dedup
  test/Windy.t.sol               Cap, role gating, burn, grant/revoke, renounce (15 tests)
  test/ZkExecutionMinter.t.sol   V1: mock-verifier proof flow + replay/tamper rejection (11 tests)
  test/ZkExecutionMinterV2.t.sol V2: tier boundaries, t-spam guard, program-hash dedup, visited
                                 cell limits, pausable, role/cap regression (25 tests)
  script/Deploy.s.sol            Base Sepolia / Base mainnet deploy + MINTER_ROLE grant
  lib/                           OpenZeppelin v5.4.0, forge-std, risc0-ethereum v3.0.1

circuit/           Risc Zero zkVM workspace
  core/            shared no_std crate:
                     - WindyInput (host→guest, risc0 serde)
                     - WindyJournalSol (guest→world, alloy sol! ABI struct)
  guest/           zkVM guest: reads WindyInput, runs the windy-lang interpreter,
                   commits the abi_encoded WindyJournalSol via env::commit_slice
  methods/         build glue: compiles the guest into ELF + image ID constants
  host/            CLI: takes --recipient + --nonce + program, proves, abi_decodes
                   the journal, verifies the receipt
  programs/        sample windy-lang programs (hello, factorial, fib, hi_windy,
                   sum_winds, hello_winds — see programs/README.md for the
                   regression baseline of journal hashes)
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

## Deployment (Base Sepolia)

### Live contracts

All three are source-verified on Basescan.

| Contract                     | Address                                                                                                                                  |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `Windy` (WNDY)               | [`0x17436284Cdc6b86F9281BBdc77161453ef1C9728`](https://sepolia.basescan.org/address/0x17436284cdc6b86f9281bbdc77161453ef1c9728#code)      |
| `ZkExecutionMinterV2` (live) | [`0x03bd354738f5776c5c00a30024192c61c3f53c97`](https://sepolia.basescan.org/address/0x03bd354738f5776c5c00a30024192c61c3f53c97#code)      |
| `IRiscZeroVerifier`          | [`0x0b144e07a0826182b6b59788c34b32bfa86fb711`](https://sepolia.basescan.org/address/0x0b144e07a0826182b6b59788c34b32bfa86fb711) (router) |
| Deployer / admin             | `0xa37558777391cbdC2866D358298782394C4204af` (DEFAULT_ADMIN_ROLE + PAUSER_ROLE on V2; DEFAULT_ADMIN_ROLE on the token)                  |
| Phase 2 `IMAGE_ID`           | `0x423061701325ba7b8f747876b75e4423200b4afba528ac9ff6514760e933b2d4`                                                                     |
| Bronze / Silver / Gold       | `0.1` / `1` / `10` WNDY (`1e17` / `1e18` / `1e19` base units; Gold is the per-proof cap)                                                 |
| Hard cap                     | 21,000,000 WNDY (immutable)                                                                                                              |
| Pre-mine                     | 0 (unchanged from initial deployment)                                                                                                    |

`MINTER_ROLE` on the Windy token is held only by `ZkExecutionMinterV2`. The earlier
`ZkExecutionMinter` (Phase 1.5 free-mint, deployed at
[`0x2b24554765B4aC8cC9030b78fdDf33fDD321853e`](https://sepolia.basescan.org/address/0x2b24554765b4ac8cc9030b78fddf33fdd321853e#code))
has had its role revoked and is paused; it is preserved on chain for reference but
cannot mint. An even earlier 1.4c demo at
[`0xc3B9329c...19C7`](https://sepolia.basescan.org/address/0xc3b9329cc1842780edacb7dea693ac63fa4a19c7#code)
is similarly retired.

`MINTER_ROLE` on `Windy` is held only by `ZkExecutionMinter`. `DEFAULT_ADMIN_ROLE` is held by the deployer and can grant `MINTER_ROLE` to additional minters as Phase 2 mining policies come online.

### Re-deploying or deploying a fresh chain

The contracts are intentionally chain-agnostic — `ZkExecutionMinter` takes the verifier address, image ID, and reward as constructor arguments. Pin those at deploy time.

### Risc Zero verifiers

For Base, prefer the **router** (selector-based dispatch over the active verifier set) so a Risc Zero version bump on their side does not strand your minter:

| Chain        | `IRiscZeroVerifier` to pass to the minter                          |
| ------------ | ------------------------------------------------------------------ |
| Base Sepolia | `0x0b144e07a0826182b6b59788c34b32bfa86fb711` (RiscZeroVerifierRouter) |
| Base mainnet | `0x0b144e07a0826182b6b59788c34b32bfa86fb711` (RiscZeroVerifierRouter) |

Source: [`risc0/risc0-ethereum/contracts/deployment.toml`](https://github.com/risc0/risc0-ethereum/blob/v3.0.1/contracts/deployment.toml).

### 1. Read the guest IMAGE_ID

```bash
cd circuit
cargo run --release -p host -- --print-image-id
# 0x<32-byte hex>
```

The image ID is `sha256(guest ELF)` and changes whenever guest source changes. Pin it in the minter constructor.

### 2. Run the deploy script

```bash
cd contracts
export VERIFIER=0x0b144e07a0826182b6b59788c34b32bfa86fb711
export IMAGE_ID=0x<paste from step 1>
export REWARD=1000000000000000000     # 1 WNDY per accepted proof
export BASE_SEPOLIA_RPC=https://sepolia.base.org
export PRIVATE_KEY=0x<deployer key with Sepolia ETH>

forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast --verify
```

The script deploys `Windy`, deploys `ZkExecutionMinter` against the verifier+image+reward triple, and grants `MINTER_ROLE` on the token to the minter. The deployer keeps `DEFAULT_ADMIN_ROLE` and can grant additional minters later.

### 3. Generate a Groth16 proof and mint

> ⚠️ **Currently blocked on Risc Zero's prover infrastructure.** `bonsai.xyz`
> stopped resolving and the [Boundless](https://docs.beboundless.xyz) successor
> service is still rolling out as of the last attempt. The contracts are
> deployed and waiting; once a Groth16 prover (Bonsai, Boundless, or a local
> wrap) becomes available, the steps below pick up unchanged.

The local prover produces STARK receipts that are too large to verify on chain. For an on-chain mint, run the host through a hosted prover (Bonsai / Boundless) so it returns a Groth16 receipt:

```bash
export BONSAI_API_URL=<hosted prover endpoint>
export BONSAI_API_KEY=<your key>

cd circuit
cargo run --release -p host -- \
  --recipient 0x<your address>
```

The host now prints an additional block at the end:

```
on-chain payload (paste into `cast send`):
  image_id: 0x...
  seal:     0x...
  journal:  0x...
```

### 4. Submit the mint transaction

```bash
cast send <minter address from step 2> \
  "mint(bytes,bytes)" <seal> <journal> \
  --rpc-url $BASE_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

`msg.sender` of the mint call doesn't matter — `WNDY.mint` goes to the `recipient` committed inside the journal, so anyone can submit the transaction on behalf of the recipient (even a relayer paying gas).

## Trust model

- `Windy.sol` is intended to be deployed once and never replaced. New mint logic ships
  as separate `Minter` contracts that receive `MINTER_ROLE`.
- The hard cap is a `constant` in code — no admin path can change it.
- Initial admin holds only `DEFAULT_ADMIN_ROLE` (no `MINTER_ROLE`); cannot mint.
- Admin is expected to migrate to a multisig and eventually `renounceRole`.
