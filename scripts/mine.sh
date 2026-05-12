#!/usr/bin/env bash
# Mine WNDY by running a windy-lang program through the full
# Risc Zero proof + ZkExecutionMinterV2.mint pipeline.
#
# Usage:    ./scripts/mine.sh <program-file>
# Example:  ./scripts/mine.sh circuit/programs/fib_gold.wnd
#
# Configurable via env (sensible Base mainnet defaults baked in):
#   ACCOUNT     Foundry keystore alias                  (deployer-mainnet)
#   MINTER      ZkExecutionMinterV2 address             (0xc566...ff02)
#   WNDY        Windy token address                     (0x8c64...53ca)
#   RPC         Base RPC                                (https://mainnet.base.org)
#   MAX_STEPS   windy VM tick cap                       (100000)
#   SEED        windy VM PRNG seed                      (0)
#   RECIPIENT   override recipient address              (auto from $ACCOUNT)
#   NONCE       fixed 32-byte hex nonce                 (random if unset)

set -euo pipefail

# ---- arg parsing ----
PROGRAM="${1:-}"
if [[ -z "$PROGRAM" ]]; then
    cat <<EOF >&2
Usage: $0 <program-file>
Example: $0 circuit/programs/fib_gold.wnd
EOF
    exit 1
fi

# ---- resolve paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$PROGRAM" = /* ]]; then
    PROGRAM_ABS="$PROGRAM"
elif [[ -f "$PROGRAM" ]]; then
    PROGRAM_ABS="$(cd "$(dirname "$PROGRAM")" && pwd)/$(basename "$PROGRAM")"
elif [[ -f "$ROOT/$PROGRAM" ]]; then
    PROGRAM_ABS="$ROOT/$PROGRAM"
else
    echo "❌ cannot find program file: $PROGRAM" >&2
    exit 1
fi

# ---- config (mainnet defaults) ----
ACCOUNT="${ACCOUNT:-deployer-mainnet}"
MINTER="${MINTER:-0xc566ab14616662ae92095a72a8cc23bf62b6ff02}"
WNDY="${WNDY:-0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca}"
RPC="${RPC:-https://mainnet.base.org}"
MAX_STEPS="${MAX_STEPS:-100000}"
SEED="${SEED:-0}"
RECIPIENT="${RECIPIENT:-$(cast wallet address --account "$ACCOUNT" 2>/dev/null)}"

if [[ -z "$RECIPIENT" ]]; then
    echo "❌ Could not derive recipient from account '$ACCOUNT'." >&2
    echo "   Set RECIPIENT=0x... explicitly or import a keystore via:" >&2
    echo "       cast wallet import $ACCOUNT --interactive" >&2
    exit 1
fi

# ---- prereqs ----
if ! command -v cast >/dev/null 2>&1; then
    echo "❌ 'cast' not found. Install Foundry: https://book.getfoundry.sh/getting-started/installation" >&2
    exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "❌ 'cargo' not found. Install Rust: https://rustup.rs" >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker is not running. Start Docker Desktop and retry (needed for Groth16 wrap)." >&2
    exit 1
fi

# ---- banner ----
echo "════════════════════════════════════════════════════════════════"
echo "  windy-coin mine"
echo "════════════════════════════════════════════════════════════════"
echo "  program:   $PROGRAM_ABS"
echo "  recipient: $RECIPIENT"
echo "  account:   $ACCOUNT"
echo "  minter:    $MINTER"
echo "  rpc:       $RPC"
echo "  max_steps: $MAX_STEPS, seed: $SEED${NONCE:+, nonce: $NONCE}"
echo "════════════════════════════════════════════════════════════════"
echo

# ---- proof generation (no password needed) ----
echo "▶ Generating Risc Zero proof — 5~10 min on first build, faster after cache."
echo "  Safe to step away. Keystore password NOT needed during this step."
echo

TMP_OUT="$(mktemp -t mine-out.XXXXXX)"
trap 'rm -f "$TMP_OUT"' EXIT

HOST_ARGS=(
    --recipient "$RECIPIENT"
    --program-file "$PROGRAM_ABS"
    --max-steps "$MAX_STEPS"
    --seed "$SEED"
)
if [[ -n "${NONCE:-}" ]]; then
    HOST_ARGS+=(--nonce "$NONCE")
fi

(
    cd "$ROOT/circuit"
    RUST_LOG="${RUST_LOG:-info}" cargo run --release -p host -- "${HOST_ARGS[@]}"
) 2>&1 | tee "$TMP_OUT"

# ---- parse seal + journal ----
SEAL=$(grep -E '^[[:space:]]*seal:[[:space:]]+0x' "$TMP_OUT" | awk '{print $2}' | tail -1)
JOURNAL=$(grep -E '^[[:space:]]*journal:[[:space:]]+0x' "$TMP_OUT" | awk '{print $2}' | tail -1)

if [[ -z "$SEAL" || -z "$JOURNAL" ]]; then
    echo >&2
    echo "❌ Failed to parse seal/journal from host output." >&2
    echo "   Possible cause: prover produced STARK instead of Groth16 (Docker needed)." >&2
    echo "   Look at the output above for the actual reason." >&2
    exit 1
fi

# ---- submit mint ----
echo
echo "════════════════════════════════════════════════════════════════"
echo "  Submitting mint tx (keystore password will be prompted)"
echo "════════════════════════════════════════════════════════════════"
echo

TX_OUT="$(mktemp -t mine-tx.XXXXXX)"
trap 'rm -f "$TMP_OUT" "$TX_OUT"' EXIT

if ! cast send "$MINTER" "mint(bytes,bytes)" "$SEAL" "$JOURNAL" \
    --rpc-url "$RPC" \
    --account "$ACCOUNT" \
    2>&1 | tee "$TX_OUT"
then
    echo >&2
    echo "❌ Mint failed. Common causes (check the revert reason above):" >&2
    echo "   • ProgramAlreadyConsumed — this program_hash was already mined" >&2
    echo "   • ScoreBelowFloor       — score < 10 (no Bronze)" >&2
    echo "   • VisitedCellsOutOfRange — visited cells outside [10, 1500]" >&2
    echo "   • Risc Zero verify revert — IMAGE_ID mismatch" >&2
    exit 1
fi

TX_HASH=$(grep -E '^transactionHash' "$TX_OUT" | awk '{print $2}' | tail -1)
STATUS=$(grep -E '^status' "$TX_OUT" | awk '{print $2}' | tail -1)

# ---- post-mint summary ----
echo
echo "════════════════════════════════════════════════════════════════"
if [[ "$STATUS" == "1" || "$STATUS" == "0x1" ]]; then
    echo "  ✅ Mint succeeded"
else
    echo "  ⚠ Mint completed (status=$STATUS) — verify on BaseScan"
fi
echo "════════════════════════════════════════════════════════════════"
if [[ -n "$TX_HASH" ]]; then
    echo "  tx:        $TX_HASH"
    echo "  basescan:  https://basescan.org/tx/$TX_HASH"
fi

BALANCE_WEI=$(cast call "$WNDY" "balanceOf(address)" "$RECIPIENT" --rpc-url "$RPC")
BALANCE=$(cast --from-wei "$BALANCE_WEI")
SUPPLY_WEI=$(cast call "$WNDY" "totalSupply()" --rpc-url "$RPC")
SUPPLY=$(cast --from-wei "$SUPPLY_WEI")

echo "  $RECIPIENT"
echo "    balance:      $BALANCE WNDY"
echo "  totalSupply:    $SUPPLY WNDY (out of 21,000,000 cap)"
echo
