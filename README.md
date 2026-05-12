# windy-coin

Proof-of-Windy: ZK-verified windy-lang execution mining for the **WNDY** token on Base.

> **Status (Phase 3 — mainnet live):** WNDY is live on Base mainnet
> ([`Windy`](https://basescan.org/address/0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca#code) at
> `0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca`, deployed 2026-05-11) on the
> **self-audit-only baseline** (61 tests, 7 fuzz × 256 runs, 100% coverage,
> Slither 0, Mythril `No issues were detected`, Pausable kill switch, Safe
> multisig admin). The deployer EOA renounced every role in the same atomic
> broadcast as the deploy — only the Safe can pause or grant new minters, and
> the 21M `MAX_SUPPLY` is a `constant` in the bytecode that nobody can change.
> The decision to skip a paid external audit (~$50k+) for this experimental /
> hobby useful-PoW token is logged in [`CLAUDE.md`](./CLAUDE.md). The Sepolia
> first mint at Silver tier
> ([tx](https://sepolia.basescan.org/tx/0xe4d6425907f22e32571690a542f879c4ef4608d00cee14b56eaac0fe9a0034d2);
> 1.0 WNDY for `puzzle_hard.wnd`) is preserved as testnet history. See
> [`docs/PHASE-2-MINING.md`](./docs/PHASE-2-MINING.md) for the mining policy,
> [`docs/TOKENOMICS.md`](./docs/TOKENOMICS.md) for the supply curve, and
> [`docs/PHASE-3-PLAN.md`](./docs/PHASE-3-PLAN.md) for the post-launch minter
> evolution.

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

## Deployment (Base mainnet)

Live since 2026-05-11. Both contracts source-verified on Basescan.

> **채굴해보고 싶다면** → [`docs/MINING-GUIDE.md`](./docs/MINING-GUIDE.md) 에 본인
> `.wnd` 프로그램을 작성해서 WNDY를 받는 end-to-end 절차가 정리돼 있다.

| Contract                     | Address                                                                                                                          |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `Windy` (WNDY)               | [`0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca`](https://basescan.org/address/0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca#code)     |
| `ZkExecutionMinterV2` (live) | [`0xc566ab14616662ae92095a72a8cc23bf62b6ff02`](https://basescan.org/address/0xc566ab14616662ae92095a72a8cc23bf62b6ff02#code)     |
| `IRiscZeroVerifier`          | [`0x0b144e07a0826182b6b59788c34b32bfa86fb711`](https://basescan.org/address/0x0b144e07a0826182b6b59788c34b32bfa86fb711) (router) |
| Admin / pauser (Safe)        | [`0x1143569f0B6D17B51b7dfff9Dfa8BbF1AdCe75D7`](https://app.safe.global/home?safe=base:0x1143569f0B6D17B51b7dfff9Dfa8BbF1AdCe75D7) (1-of-1 Safe; signer set can be expanded or renounced later) |
| Phase 2 `IMAGE_ID`           | `0xb78810f2e9557907cf9865797240661414e8102326cfdd8d8bc7879d58ca57cb`                                                             |
| Bronze / Silver / Gold       | `0.1` / `1` / `10` WNDY (`1e17` / `1e18` / `1e19` base units; Gold is the per-proof cap)                                         |
| Hard cap                     | 21,000,000 WNDY (immutable `constant`)                                                                                           |
| Deploy tx                    | [`0x8ec7640ccfed9c2d3787be6bf47d8a612abb7394e4a973e511ebb99634d56d7c`](https://basescan.org/tx/0x8ec7640ccfed9c2d3787be6bf47d8a612abb7394e4a973e511ebb99634d56d7c) (full 9-tx atomic broadcast in [`contracts/broadcast/DeployMainnet.s.sol/8453/run-latest.json`](contracts/broadcast/DeployMainnet.s.sol/8453/run-latest.json)) |

### Post-deploy trust model

- The deployer EOA holds **zero roles** on both contracts — `renounceRole` is called for `DEFAULT_ADMIN_ROLE` (token + minter) and `PAUSER_ROLE` (minter) inside the same atomic broadcast as the deploy ([`DeployMainnet.s.sol`](contracts/script/DeployMainnet.s.sol)). After block N+1 the deployer is indistinguishable from any other address.
- The Safe multisig holds `DEFAULT_ADMIN_ROLE` on both contracts and `PAUSER_ROLE` on the minter. It can pause the minter or grant `MINTER_ROLE` to a future Phase 3 minter — it cannot mint WNDY directly.
- `MINTER_ROLE` on `Windy` is held only by `ZkExecutionMinterV2`. The sole path for new WNDY into existence is a Risc Zero proof verifying a windy-lang execution against the pinned `IMAGE_ID`, which then mints the tier reward to the `recipient` committed inside the journal.
- The 21M `MAX_SUPPLY` is a `constant` in the bytecode of `Windy.sol`. Even the Safe cannot raise it.

### First mainnet mint (Silver tier — `puzzle_hard.wnd`)

| Field            | Value                                                                                                                       |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Date             | 2026-05-11                                                                                                                  |
| Tx               | [`0x97310d285fd88d1393c9ac858c71ca9a10dcb369601e08a6bdad415e734ac54c`](https://basescan.org/tx/0x97310d285fd88d1393c9ac858c71ca9a10dcb369601e08a6bdad415e734ac54c) (block 45,894,604) |
| Recipient        | `0xCE1339F8F499aB0cA276F949F636082c9C305167` (deployer EOA — no longer privileged, just a normal address)                    |
| Source program   | `circuit/programs/puzzle_hard.wnd` (4 IPs, 3 SPLITs, 18 ticks — same program that landed Silver on Sepolia)                  |
| `program_hash`   | `0x9b1031224069c0d2e5398ffa4ddca016a07979a30f1201f44078fc288939a31c`                                                         |
| `output_hash`    | `0xa3a2a5f918f186fbf86c27f190a7b1fc83fb7c3ac0efbc82d4239c82d06c54ef` (`sha256("1 2 4 3 2 6 5 1 7 4 ")`)                      |
| `visited_cells`  | 15                                                                                                                          |
| Score            | **34.30** (`scoreX1000 = 34300`)                                                                                            |
| Tier / reward    | **Silver** / `1.0 WNDY`                                                                                                     |
| `totalSupply`    | 1.0 WNDY after this mint (pre-mine was 0; this is genesis circulating supply)                                              |

A second `cast send` of the same `(seal, journal)` reverts with `ProgramAlreadyConsumed(0x9b1031...931c)` — confirming the first-claim dedup policy is live on mainnet. The `puzzle_hard.wnd` program is now permanently unmineable.

For writing your own `.wnd` to mine WNDY, see [`docs/MINING-GUIDE.md`](docs/MINING-GUIDE.md).

## Deployment (Base Sepolia)

Testnet record — preserved for the audit trail.

### Live contracts

All three are source-verified on Basescan.

| Contract                     | Address                                                                                                                                  |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `Windy` (WNDY)               | [`0x17436284Cdc6b86F9281BBdc77161453ef1C9728`](https://sepolia.basescan.org/address/0x17436284cdc6b86f9281bbdc77161453ef1c9728#code)      |
| `ZkExecutionMinterV2` (live) | [`0x5e24Ff21894e54BC315AD17ffa29be3844ff3dC3`](https://sepolia.basescan.org/address/0x5e24ff21894e54bc315ad17ffa29be3844ff3dc3#code)      |
| `IRiscZeroVerifier`          | [`0x0b144e07a0826182b6b59788c34b32bfa86fb711`](https://sepolia.basescan.org/address/0x0b144e07a0826182b6b59788c34b32bfa86fb711) (router) |
| Deployer / admin             | `0xa37558777391cbdC2866D358298782394C4204af` (DEFAULT_ADMIN_ROLE + PAUSER_ROLE on V2; DEFAULT_ADMIN_ROLE on the token)                  |
| Phase 2 `IMAGE_ID`           | `0xb78810f2e9557907cf9865797240661414e8102326cfdd8d8bc7879d58ca57cb`                                                                     |
| Bronze / Silver / Gold       | `0.1` / `1` / `10` WNDY (`1e17` / `1e18` / `1e19` base units; Gold is the per-proof cap)                                                 |
| Hard cap                     | 21,000,000 WNDY (immutable)                                                                                                              |
| Total supply                 | **1.0 WNDY** (one Silver mint to the deployer, see "First mint" below)                                                                  |

`MINTER_ROLE` on the Windy token is held only by the live `ZkExecutionMinterV2` above.
Earlier minter contracts have all had `MINTER_ROLE` revoked and been paused; they are
preserved on chain for the audit trail but cannot mint:

- [`0x03bd354738f5776c5c00a30024192c61c3f53c97`](https://sepolia.basescan.org/address/0x03bd354738f5776c5c00a30024192c61c3f53c97#code)
  — earlier V2 with the Cargo.lock-pinned `IMAGE_ID 0x423061…2d4`, retired during the
  V2 redeploy that wired the on-chain selector prefix into the host's printed seal.
- [`0x2b24554765B4aC8cC9030b78fdDf33fDD321853e`](https://sepolia.basescan.org/address/0x2b24554765b4ac8cc9030b78fddf33fdd321853e#code)
  — Phase 1.5 free-mint contract.
- [`0xc3B9329cc1842780eDacb7dEa693Ac63fA4A19C7`](https://sepolia.basescan.org/address/0xc3b9329cc1842780edacb7dea693ac63fa4a19c7#code)
  — original Phase 1.4c demo.

### First mint (Silver tier — `puzzle_hard.wnd`)

| Field                    | Value                                                                                                                       |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Tx                       | [`0xe4d6425907f22e32571690a542f879c4ef4608d00cee14b56eaac0fe9a0034d2`](https://sepolia.basescan.org/tx/0xe4d6425907f22e32571690a542f879c4ef4608d00cee14b56eaac0fe9a0034d2) |
| Recipient                | `0xa37558777391cbdC2866D358298782394C4204af`                                                                                |
| Source program           | `circuit/programs/puzzle_hard.wnd` (4 IPs, 3 SPLITs, 18 ticks)                                                              |
| `program_hash`           | `0x9b1031224069c0d2e5398ffa4ddca016a07979a30f1201f44078fc288939a31c`                                                        |
| `output_hash`            | `0xa3a2a5f918f186fbf86c27f190a7b1fc83fb7c3ac0efbc82d4239c82d06c54ef` (`sha256("1 2 4 3 2 6 5 1 7 4 ")`)                     |
| `visited_cells`          | 15                                                                                                                          |
| Score                    | **34.30** (= `34_300 / 1000`)                                                                                               |
| Tier / reward            | **Silver** / `1.0 WNDY`                                                                                                     |
| Selector                 | `0x73c457ba` (Risc Zero Groth16 v3.0.0)                                                                                     |
| Gas                      | 376,377                                                                                                                     |

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

> The local risc0 prover wraps STARKs into Groth16 receipts via the
> `risczero/risc0-groth16-prover` Docker image (multi-arch — runs on
> Apple Silicon natively). Bonsai is not required for the testnet.
> The host's `prove_with_opts(env, ELF, &ProverOpts::groth16())` call
> shells out to that container; ensure Docker Desktop is running.

```bash
cd circuit
cargo run --release -p host -- \
  --recipient 0x<your address> \
  --program-file programs/puzzle_hard.wnd
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
