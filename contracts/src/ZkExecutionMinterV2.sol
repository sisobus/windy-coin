// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {Windy} from "./Windy.sol";

/// @title  ZkExecutionMinterV2 — Phase 2 tier-based minter for the WNDY token
/// @notice The free-mint Phase 1 minter is replaced by this contract once
///         `MINTER_ROLE` is migrated. Every successful proof is graded by
///         a bounded score formula and pays one of three fixed rewards
///         (Bronze / Silver / Gold). Sub-Bronze submissions revert; the
///         miner's `nonce` and `programHash` are preserved for a denser
///         resubmit. See `docs/PHASE-2-MINING.md` for the design rationale.
/// @dev    All scoring is integer-arithmetic. The float formula in the
///         spec is rendered as `coreX10 × factorX100` so that the
///         human-readable score equals `scoreX1000 / 1000`. Tier cutoffs
///         compare against `scoreX1000` directly (e.g. score ≥ 10 is
///         `scoreX1000 ≥ 10_000`).
contract ZkExecutionMinterV2 is AccessControl, Pausable {
    /// @notice Address authorized to call `pause()` / `unpause()`.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Reward tier classification.
    enum Tier {
        None,
        Bronze,
        Silver,
        Gold
    }

    /// @notice Layout MUST match `WindyJournalSol` in
    ///         `circuit/core/src/lib.rs`. 14 head slots, 448 ABI bytes.
    struct WindyJournal {
        // Phase 1 fields
        address recipient;
        bytes32 nonce;
        bytes32 programHash;
        bytes32 outputHash;
        int32 exitCode;
        uint64 steps;
        // Phase 2 fields
        uint16 hardOpcodeBitmap;
        uint64 maxAliveIps;
        uint64 spawnedIps;
        uint64 gridWrites;
        uint64 branchCount;
        uint64 visitedCells;
        uint32 effectiveCells; // advisory — not used by the score
        uint32 totalGridCells; // advisory — not used by the score
    }

    // Hard-opcode bit assignments — must match
    // `circuit/core/src/lib.rs` and `windy-lang::vm::VmMetrics::BIT_*`.
    uint16 internal constant BIT_T = 1 << 0; // SPLIT
    uint16 internal constant BIT_P = 1 << 1; // GRID_PUT
    uint16 internal constant BIT_G = 1 << 2; // GRID_GET
    uint16 internal constant BIT_IFH = 1 << 3; // _
    uint16 internal constant BIT_IFV = 1 << 4; // |
    uint16 internal constant BIT_GUST = 1 << 5; // ≫
    uint16 internal constant BIT_CALM = 1 << 6; // ≪
    uint16 internal constant BIT_TURB = 1 << 7; // ~
    uint16 internal constant BIT_TRAMP = 1 << 8; // #
    uint16 internal constant BIT_STR = 1 << 9; // "

    // Eligibility window for `visitedCells` — see §4 of the policy spec.
    uint64 internal constant MIN_VISITED_CELLS = 10;
    uint64 internal constant MAX_VISITED_CELLS = 1500;

    // Cap each metric so an adversary can't push the score arbitrarily
    // high by inflating one of them.
    uint256 internal constant CAP_SPAWNED = 20;
    uint256 internal constant CAP_WRITES = 100;
    uint256 internal constant CAP_BRANCHES = 100;

    // Tier cutoffs, compared against `scoreX1000`. The human-readable
    // floor for Bronze is 10, for Silver 30, for Gold 70.
    uint256 internal constant TIER_BRONZE_FLOOR_X1000 = 10_000;
    uint256 internal constant TIER_SILVER_FLOOR_X1000 = 30_000;
    uint256 internal constant TIER_GOLD_FLOOR_X1000 = 70_000;

    /// @notice The Risc Zero on-chain verifier.
    IRiscZeroVerifier public immutable VERIFIER;

    /// @notice The WNDY token. Must have granted `MINTER_ROLE` to this
    ///         contract for `mint()` to succeed.
    Windy public immutable WNDY;

    /// @notice Image ID of the windy-coin Phase 2 guest binary.
    bytes32 public immutable IMAGE_ID;

    /// @notice Reward at the Bronze tier, in WNDY base units.
    uint256 public immutable REWARD_BRONZE;

    /// @notice Reward at the Silver tier, in WNDY base units.
    uint256 public immutable REWARD_SILVER;

    /// @notice Reward at the Gold tier, in WNDY base units. Doubles as
    ///         the per-proof maximum mintable amount.
    uint256 public immutable REWARD_GOLD;

    /// @notice Tracks consumed proof nonces.
    mapping(bytes32 => bool) public consumedNonce;

    /// @notice Tracks consumed program hashes (first-claim wins).
    mapping(bytes32 => bool) public consumedProgram;

    error NonceAlreadyConsumed(bytes32 nonce);
    error ProgramAlreadyConsumed(bytes32 programHash);
    error VisitedCellsOutOfRange(uint64 visitedCells);
    error ScoreBelowFloor(uint256 scoreX1000);

    /// @notice Emitted on a successful mint. `scoreX1000` is exactly
    ///         1000× the score in §5; divide by 1000 to recover the
    ///         human-readable value.
    event Minted(
        address indexed recipient,
        bytes32 indexed nonce,
        bytes32 programHash,
        bytes32 outputHash,
        int32 exitCode,
        uint64 steps,
        uint64 visitedCells,
        uint256 scoreX1000,
        Tier tier,
        uint256 amount
    );

    /// @param verifier      `IRiscZeroVerifier` to delegate proof verification to.
    /// @param wndy          `Windy` token. Deployer is responsible for
    ///                      granting `MINTER_ROLE` on `wndy` to this contract.
    /// @param imageId       Guest ELF digest the verifier will require.
    /// @param rewardBronze  Bronze-tier mint amount in WNDY base units.
    /// @param rewardSilver  Silver-tier mint amount in WNDY base units.
    /// @param rewardGold    Gold-tier mint amount, also the per-proof cap.
    constructor(
        IRiscZeroVerifier verifier,
        Windy wndy,
        bytes32 imageId,
        uint256 rewardBronze,
        uint256 rewardSilver,
        uint256 rewardGold
    ) {
        VERIFIER = verifier;
        WNDY = wndy;
        IMAGE_ID = imageId;
        REWARD_BRONZE = rewardBronze;
        REWARD_SILVER = rewardSilver;
        REWARD_GOLD = rewardGold;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    /// @notice Halt new mints.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume new mints.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Verify a windy-lang execution proof, grade it, and mint the
    ///         tier-appropriate reward.
    /// @dev Order is Checks-Effects-Interactions: verify, decode, gate,
    ///      score, tier, write, emit, mint. Both `consumedProgram` and
    ///      `consumedNonce` are written *only* on a tier ≥ Bronze
    ///      result, so a sub-Bronze submission can be retried after the
    ///      miner densifies the source (which would change
    ///      `program_hash` anyway).
    /// @param seal     Risc Zero seal bytes.
    /// @param journal  ABI-encoded `WindyJournal` (448 bytes).
    function mint(bytes calldata seal, bytes calldata journal) external whenNotPaused {
        bytes32 journalDigest = sha256(journal);
        VERIFIER.verify(seal, IMAGE_ID, journalDigest);

        WindyJournal memory j = abi.decode(journal, (WindyJournal));

        // Eligibility — order is fastest-fail first so a clearly bad
        // submission burns the least gas.
        if (consumedProgram[j.programHash]) revert ProgramAlreadyConsumed(j.programHash);
        if (consumedNonce[j.nonce]) revert NonceAlreadyConsumed(j.nonce);
        if (j.visitedCells < MIN_VISITED_CELLS || j.visitedCells > MAX_VISITED_CELLS) {
            revert VisitedCellsOutOfRange(j.visitedCells);
        }

        (uint256 scoreX1000, Tier tier) = computeScore(j);

        if (tier == Tier.None) revert ScoreBelowFloor(scoreX1000);

        uint256 reward;
        if (tier == Tier.Bronze) reward = REWARD_BRONZE;
        else if (tier == Tier.Silver) reward = REWARD_SILVER;
        else reward = REWARD_GOLD;

        consumedProgram[j.programHash] = true;
        consumedNonce[j.nonce] = true;

        emit Minted(
            j.recipient,
            j.nonce,
            j.programHash,
            j.outputHash,
            j.exitCode,
            j.steps,
            j.visitedCells,
            scoreX1000,
            tier,
            reward
        );

        WNDY.mint(j.recipient, reward);
    }

    /// @notice Pure scoring of a journal — exposed so off-chain tooling
    ///         can pre-grade a proof before paying gas.
    /// @return scoreX1000  Score × 1000 (so the human value is /1000).
    /// @return tier        The reward tier the score lands in.
    function computeScore(WindyJournal memory j) public pure returns (uint256 scoreX1000, Tier tier) {
        // diversity_weighted: sum of per-opcode weights, max 41.
        uint256 divW = 0;
        if (j.hardOpcodeBitmap & BIT_T != 0) divW += 8;
        if (j.hardOpcodeBitmap & BIT_P != 0) divW += 8;
        if (j.hardOpcodeBitmap & BIT_G != 0) divW += 6;
        if (j.hardOpcodeBitmap & BIT_IFH != 0) divW += 4;
        if (j.hardOpcodeBitmap & BIT_IFV != 0) divW += 4;
        if (j.hardOpcodeBitmap & BIT_GUST != 0) divW += 3;
        if (j.hardOpcodeBitmap & BIT_CALM != 0) divW += 3;
        if (j.hardOpcodeBitmap & BIT_TURB != 0) divW += 2;
        if (j.hardOpcodeBitmap & BIT_TRAMP != 0) divW += 2;
        if (j.hardOpcodeBitmap & BIT_STR != 0) divW += 1;

        // log2_floor(max(maxAliveIps, 1)). With Math.Rounding.Floor, this
        // matches the spec's `⌊log2(...)⌋` exactly.
        uint256 ips = j.maxAliveIps == 0 ? 1 : uint256(j.maxAliveIps);
        uint256 log2Part = Math.log2(ips, Math.Rounding.Floor);

        // Spawned bonus with the t-spam guard: if more than half of the
        // visited cells are SPLITs, the bonus zeroes out. The `maxAliveIps`
        // contribution above is unaffected.
        uint256 visitedSafe = j.visitedCells == 0 ? 1 : uint256(j.visitedCells);
        uint256 spawnedCapped;
        if (uint256(j.spawnedIps) * 2 > visitedSafe) {
            spawnedCapped = 0;
        } else {
            spawnedCapped = uint256(j.spawnedIps) > CAP_SPAWNED ? CAP_SPAWNED : uint256(j.spawnedIps);
        }

        uint256 writesCapped = uint256(j.gridWrites) > CAP_WRITES ? CAP_WRITES : uint256(j.gridWrites);
        uint256 branchesCapped = uint256(j.branchCount) > CAP_BRANCHES ? CAP_BRANCHES : uint256(j.branchCount);

        // core × 10 = log2 × 100 + spawned × 15 + writes × 3 + branches × 2
        // (rendered from the float `log2 × 10 + spawned × 1.5 + writes ×
        // 0.3 + branches × 0.2`)
        uint256 coreX10 = log2Part * 100 + spawnedCapped * 15 + writesCapped * 3 + branchesCapped * 2;

        // factor × 100 = 100 + diversity × 5
        // (rendered from the float `1 + diversity × 0.05`)
        uint256 factorX100 = 100 + divW * 5;

        // score × 1000 = (core × 10) × (factor × 100)
        scoreX1000 = coreX10 * factorX100;

        if (scoreX1000 < TIER_BRONZE_FLOOR_X1000) tier = Tier.None;
        else if (scoreX1000 < TIER_SILVER_FLOOR_X1000) tier = Tier.Bronze;
        else if (scoreX1000 < TIER_GOLD_FLOOR_X1000) tier = Tier.Silver;
        else tier = Tier.Gold;
    }
}
