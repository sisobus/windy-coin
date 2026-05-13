#!/usr/bin/env bash
# Mine WNDY by running a windy-lang program through the full
# Risc Zero proof + ZkExecutionMinterV2.mint pipeline.
#
# Usage:
#   ./scripts/mine.sh <program-file>             # real mint on mainnet
#   ./scripts/mine.sh --dry-run <program-file>   # score-only, no tx, no docker
#
# Dry-run path runs the zkVM guest without proving (no Groth16 wrap,
# no Docker, ~seconds), then calls `ZkExecutionMinterV2.computeScore`
# on-chain to predict score + tier. Real path additionally generates
# the Groth16 receipt (~5-10 min) and broadcasts the mint tx.
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
DRY_RUN=0
PROGRAM=""
for arg in "$@"; do
    case "$arg" in
        --dry-run|-d) DRY_RUN=1 ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            if [[ -n "$PROGRAM" ]]; then
                echo "❌ multiple program files given: '$PROGRAM' and '$arg'" >&2
                exit 1
            fi
            PROGRAM="$arg"
            ;;
    esac
done

if [[ -z "$PROGRAM" ]]; then
    cat <<EOF >&2
Usage:
  $0 <program-file>             real mint
  $0 --dry-run <program-file>   score-only, no tx, no docker
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
RECIPIENT="${RECIPIENT:-$(cast wallet address --account "$ACCOUNT" 2>/dev/null || echo)}"

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
if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! docker info >/dev/null 2>&1; then
        echo "❌ Docker is not running. Start Docker Desktop and retry (needed for Groth16 wrap)." >&2
        echo "   Or run with --dry-run for a score-only check that skips Groth16." >&2
        exit 1
    fi
fi

# ---- banner ----
if [[ "$DRY_RUN" -eq 1 ]]; then
    MODE="dry-run (score-only, no tx)"
else
    MODE="mint (real Base mainnet tx)"
fi

echo "════════════════════════════════════════════════════════════════"
echo "  windy-coin mine — $MODE"
echo "════════════════════════════════════════════════════════════════"
echo "  program:   $PROGRAM_ABS"
echo "  recipient: $RECIPIENT"
echo "  account:   $ACCOUNT"
echo "  minter:    $MINTER"
echo "  rpc:       $RPC"
echo "  max_steps: $MAX_STEPS, seed: $SEED${NONCE:+, nonce: $NONCE}"
echo "════════════════════════════════════════════════════════════════"
echo

# ---- run guest ----
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
if [[ "$DRY_RUN" -eq 1 ]]; then
    HOST_ARGS+=(--score-only)
    echo "▶ Executing zkVM guest (no proof, ~seconds)..."
else
    echo "▶ Generating Risc Zero proof — 5~10 min on first build, faster after cache."
    echo "  Safe to step away. Keystore password NOT needed during this step."
fi
echo

(
    cd "$ROOT/circuit"
    RUST_LOG="${RUST_LOG:-info}" cargo run --release -p host -- "${HOST_ARGS[@]}"
) 2>&1 | tee "$TMP_OUT"

# ---- parse journal ----
if [[ "$DRY_RUN" -eq 1 ]]; then
    # In score-only mode, the journal hex is on the line after
    # "journal (for off-chain `computeScore` grading):"
    JOURNAL=$(grep -E '^[[:space:]]*0x[0-9a-fA-F]+$' "$TMP_OUT" | tail -1 | tr -d '[:space:]')
else
    JOURNAL=$(grep -E '^[[:space:]]*journal:[[:space:]]+0x' "$TMP_OUT" | awk '{print $2}' | tail -1)
    SEAL=$(grep -E '^[[:space:]]*seal:[[:space:]]+0x' "$TMP_OUT" | awk '{print $2}' | tail -1)
fi

if [[ -z "$JOURNAL" ]]; then
    echo >&2
    echo "❌ Failed to parse journal from host output." >&2
    exit 1
fi

# Also parse visited_cells from human-readable metrics for eligibility warning
VISITED=$(grep -E '^[[:space:]]*visited_cells:[[:space:]]+[0-9]+' "$TMP_OUT" | head -1 | awk '{print $2}' || echo 0)

# ---- on-chain score (computeScore is `pure`, free) ----
echo
echo "▶ Grading on-chain via ZkExecutionMinterV2.computeScore..."

SELECTOR=$(cast sig "computeScore((address,bytes32,bytes32,bytes32,int32,uint64,uint16,uint64,uint64,uint64,uint64,uint64,uint32,uint32))")
CALLDATA="${SELECTOR}${JOURNAL#0x}"
SCORE_RESULT=$(cast call "$MINTER" "$CALLDATA" --rpc-url "$RPC")

# Result is ABI-encoded (uint256 scoreX1000, uint8 tier) = 64 bytes
SCORE_HEX="0x${SCORE_RESULT:2:64}"
TIER_HEX="0x${SCORE_RESULT:66:64}"
SCORE_X1000=$(cast --to-dec "$SCORE_HEX")
TIER=$(cast --to-dec "$TIER_HEX")

case "$TIER" in
    0) TIER_NAME="None"   ; REWARD="0 (revert: ScoreBelowFloor)" ;;
    1) TIER_NAME="Bronze" ; REWARD="0.1 WNDY" ;;
    2) TIER_NAME="Silver" ; REWARD="1.0 WNDY" ;;
    3) TIER_NAME="Gold"   ; REWARD="10.0 WNDY" ;;
    *) TIER_NAME="?"      ; REWARD="?" ;;
esac

# Display score as decimal with 3 fractional digits
SCORE_INT=$((SCORE_X1000 / 1000))
SCORE_FRAC=$(printf "%03d" $((SCORE_X1000 % 1000)))

echo
echo "════════════════════════════════════════════════════════════════"
echo "  Grade"
echo "════════════════════════════════════════════════════════════════"
echo "  score:    ${SCORE_INT}.${SCORE_FRAC} (= scoreX1000 ${SCORE_X1000})"
echo "  tier:     ${TIER} → ${TIER_NAME}"
echo "  reward:   ${REWARD}"

# Eligibility warnings
ELIGIBLE=1
if [[ "$VISITED" -lt 10 ]] 2>/dev/null || [[ "$VISITED" -gt 1500 ]] 2>/dev/null; then
    echo "  ⚠ visited_cells = $VISITED is outside [10, 1500] — mint would revert"
    echo "    with VisitedCellsOutOfRange before scoring is even consulted."
    ELIGIBLE=0
fi
if [[ "$TIER" == "0" ]]; then
    echo "  ⚠ score < 10 → tier None — mint would revert with ScoreBelowFloor."
    ELIGIBLE=0
fi
echo "════════════════════════════════════════════════════════════════"

# ---- dry-run: stop here ----
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    if [[ "$ELIGIBLE" -eq 1 ]]; then
        echo "Looks mintable. Re-run without --dry-run to actually claim ${REWARD}."
    else
        echo "Not mintable as-is. Adjust the program and re-run."
    fi
    exit 0
fi

# ---- submit mint ----
if [[ -z "${SEAL:-}" ]]; then
    echo "❌ Real mint requires a seal but none was parsed from host output." >&2
    exit 1
fi

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
