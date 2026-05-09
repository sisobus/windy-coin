# Indexing the WNDY mining stream

The on-chain `Minted` event carries every field a downstream analytics
or frontend pipeline could want — recipient, score, tier, the four
metric counters, the proof's program/output hashes — so an off-chain
indexer is one stream + one decoder, no extra contract calls needed.

This document sketches two ways to wire that up. Pick the one that
matches the hosting story you already have.

## Event signature

```solidity
event Minted(
    address indexed recipient,
    bytes32 indexed nonce,
    bytes32 programHash,
    bytes32 outputHash,
    int32 exitCode,
    uint64 steps,
    uint64 visitedCells,
    uint256 scoreX1000,
    Tier tier,            // 0 None, 1 Bronze, 2 Silver, 3 Gold
    uint256 amount        // WNDY base units (1e18 = 1 WNDY)
);
```

Topic 0 is `keccak256("Minted(address,bytes32,bytes32,bytes32,int32,uint64,uint64,uint256,uint8,uint256)")`.
Topic 1 is the recipient address (32-byte left-padded). Topic 2 is the
nonce. The remaining fields live in `data` in the order declared.

`scoreX1000` divides by 1000 for the human score: `34_300 → 34.30`.
`tier` is the enum index — most clients render `["None", "Bronze",
"Silver", "Gold"][tier]`.

## Option A — The Graph subgraph

Most analytics consumers expect a GraphQL endpoint.

`subgraph.yaml`:

```yaml
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum
    name: ZkExecutionMinterV2
    network: base-sepolia                  # change to `base` for mainnet
    source:
      address: "0x5e24Ff21894e54BC315AD17ffa29be3844ff3dC3"
      abi: ZkExecutionMinterV2
      startBlock: 41401894                 # block of the first mint tx
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Mint
        - Miner
        - Program
      abis:
        - name: ZkExecutionMinterV2
          file: ./abis/ZkExecutionMinterV2.json
      eventHandlers:
        - event: >
            Minted(
              indexed address,
              indexed bytes32,
              bytes32,
              bytes32,
              int32,
              uint64,
              uint64,
              uint256,
              uint8,
              uint256
            )
          handler: handleMinted
      file: ./src/mapping.ts
```

`schema.graphql`:

```graphql
type Mint @entity(immutable: true) {
  id: Bytes!                       # tx hash + log index
  recipient: Bytes!
  nonce: Bytes!
  programHash: Bytes!
  outputHash: Bytes!
  exitCode: Int!
  steps: BigInt!
  visitedCells: BigInt!
  scoreX1000: BigInt!
  tier: String!                    # "Bronze" | "Silver" | "Gold"
  amount: BigInt!
  blockNumber: BigInt!
  blockTimestamp: BigInt!
  txHash: Bytes!
}

type Miner @entity {
  id: Bytes!                       # recipient address
  totalMints: BigInt!
  totalAmount: BigInt!
  bronzeCount: BigInt!
  silverCount: BigInt!
  goldCount: BigInt!
  firstMintBlock: BigInt!
  lastMintBlock: BigInt!
}

type Program @entity(immutable: true) {
  id: Bytes!                       # programHash
  miner: Bytes!
  tier: String!
  amount: BigInt!
  visitedCells: BigInt!
  blockNumber: BigInt!
}
```

Deploy via the standard `graph deploy` flow against The Graph hosted
service or a self-hosted Graph Node. Frontends then run GraphQL
queries — e.g. "top 10 miners this week" or "tier distribution since
launch".

## Option B — Lightweight cast-based scrape

If running a Graph Node is overkill, a Bash + cast script over a cron
keeps it simple. Drop this in `scripts/indexer.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

MINTER=0x5e24Ff21894e54BC315AD17ffa29be3844ff3dC3
RPC=${BASE_SEPOLIA_RPC:-https://sepolia.base.org}
STATE_FILE=${STATE_FILE:-/var/lib/wndy-indexer/state.json}
mkdir -p "$(dirname "$STATE_FILE")"

last_block=$(jq -r '.last_block // 41401890' "$STATE_FILE" 2>/dev/null || echo 41401890)
head=$(cast block-number --rpc-url "$RPC")

# event Minted(address,bytes32,bytes32,bytes32,int32,uint64,uint64,uint256,uint8,uint256)
TOPIC0=$(cast keccak "Minted(address,bytes32,bytes32,bytes32,int32,uint64,uint64,uint256,uint8,uint256)")

cast logs \
  --address "$MINTER" \
  --from-block "$((last_block + 1))" \
  --to-block "$head" \
  "$TOPIC0" \
  --rpc-url "$RPC" \
  --json \
| jq -c '.[] | {
    txHash: .transactionHash,
    block: (.blockNumber | tonumber),
    recipient: .topics[1],
    nonce: .topics[2],
    data: .data
  }' \
| while IFS= read -r row; do
    echo "$row"   # ship to your analytics target — Postgres, Datadog, etc.
  done

echo "{\"last_block\":$head}" > "$STATE_FILE"
```

Run it on cron every minute. The `data` field is a single hex blob;
decode the seven non-indexed parameters with
`cast --abi-decode "Minted(bytes32,bytes32,int32,uint64,uint64,uint256,uint8,uint256)" <data>`
or in your downstream pipeline.

This option costs nothing beyond the RPC quota and keeps state in a
single JSON file, so it's the right fit for an early-stage project.

## Aggregations to ship first

| Question                                | Source                                                           |
| --------------------------------------- | ---------------------------------------------------------------- |
| Cumulative WNDY supply curve over time  | `sum(amount)` partitioned by `blockTimestamp`                    |
| Tier mix since launch                   | `count() by tier`                                                |
| Average score per tier                  | `avg(scoreX1000) by tier / 1000`                                 |
| Top miners by reward                    | `Miner` entity `totalAmount desc`                                |
| Programs that hit Gold                  | `Program where tier == "Gold"` (rare; surface them)              |
| Latency since first mint                | block-by-block accrual against the 21M cap to estimate time-to-cap |

The `consumedProgram` first-claim rule means `programHash` is unique
per `Mint` — useful for a "program of the day" view that links the
hash to a (separately-indexed) IPFS pin of the source if the miner
chooses to publish it.

## What this indexer is *not* for

- **Verifying proofs.** The on-chain verifier already did that; the
  indexer just rebroadcasts what the chain agreed on.
- **Pricing.** WNDY has no oracle source as of writing. Listings, if
  any, will provide their own market data.
- **Identity / KYC.** `recipient` is an address. The indexer does not
  attempt to resolve ENS, multi-sig membership, or any off-chain
  identity.
