// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Windy} from "../src/Windy.sol";
import {ZkExecutionMinterV2} from "../src/ZkExecutionMinterV2.sol";
import {RiscZeroMockVerifier} from "risc0/test/RiscZeroMockVerifier.sol";
import {Receipt as RiscZeroReceipt} from "risc0/IRiscZeroVerifier.sol";

contract ZkExecutionMinterV2Test is Test {
    Windy public wndy;
    ZkExecutionMinterV2 public minter;
    RiscZeroMockVerifier public mockVerifier;

    bytes32 public constant IMAGE_ID = bytes32(uint256(0xbeef));
    bytes4 public constant SELECTOR = bytes4(0x12345678);
    uint256 public constant REWARD_BRONZE = 0.1 ether; // 1e17
    uint256 public constant REWARD_SILVER = 1 ether; // 1e18
    uint256 public constant REWARD_GOLD = 10 ether; // 1e19

    address public recipient = address(0xC0FFEE);

    // Hard-opcode bit constants — kept aligned with the contract.
    uint16 internal constant BIT_T = 1 << 0;
    uint16 internal constant BIT_P = 1 << 1;
    uint16 internal constant BIT_G = 1 << 2;
    uint16 internal constant BIT_IFH = 1 << 3;
    uint16 internal constant BIT_IFV = 1 << 4;
    uint16 internal constant BIT_GUST = 1 << 5;
    uint16 internal constant BIT_CALM = 1 << 6;
    uint16 internal constant BIT_TURB = 1 << 7;
    uint16 internal constant BIT_TRAMP = 1 << 8;
    uint16 internal constant BIT_STR = 1 << 9;

    event Minted(
        address indexed recipient,
        bytes32 indexed nonce,
        bytes32 programHash,
        bytes32 outputHash,
        int32 exitCode,
        uint64 steps,
        uint64 visitedCells,
        uint256 scoreX1000,
        ZkExecutionMinterV2.Tier tier,
        uint256 amount
    );

    function setUp() public {
        wndy = new Windy();
        mockVerifier = new RiscZeroMockVerifier(SELECTOR);
        minter = new ZkExecutionMinterV2(
            mockVerifier, wndy, IMAGE_ID, REWARD_BRONZE, REWARD_SILVER, REWARD_GOLD
        );
        wndy.grantRole(wndy.MINTER_ROLE(), address(minter));
    }

    // -- helpers ----------------------------------------------------------

    /// @dev Build a fully-specified journal. Defaults match a near-Bronze
    /// puzzle_hard-shaped proof unless overridden.
    function _journalDefaults() internal view returns (ZkExecutionMinterV2.WindyJournal memory) {
        return ZkExecutionMinterV2.WindyJournal({
            recipient: recipient,
            nonce: bytes32(uint256(1)),
            programHash: bytes32(uint256(0x1111)),
            outputHash: bytes32(uint256(0x2222)),
            exitCode: int32(0),
            steps: uint64(20),
            hardOpcodeBitmap: BIT_T,
            maxAliveIps: 4,
            spawnedIps: 3,
            gridWrites: 0,
            branchCount: 0,
            visitedCells: 15,
            effectiveCells: 17,
            totalGridCells: 17
        });
    }

    function _encode(ZkExecutionMinterV2.WindyJournal memory j) internal pure returns (bytes memory) {
        return abi.encode(j);
    }

    function _mockProve(bytes memory journal) internal view returns (bytes memory seal) {
        bytes32 digest = sha256(journal);
        RiscZeroReceipt memory r = mockVerifier.mockProve(IMAGE_ID, digest);
        return r.seal;
    }

    function _mintWith(ZkExecutionMinterV2.WindyJournal memory j) internal {
        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);
        minter.mint(seal, journal);
    }

    // -- score boundary tests ---------------------------------------------

    function test_Score_PuzzleHard_Silver() public {
        // The puzzle_hard.wnd shape, measured against the v2.2.1 guest:
        //   diversity = 8 (t),
        //   max_alive_ips = 4 → log2 part = 20,
        //   spawned = 3, visited = 15, density 0.20 < 0.5 → spawned bonus 4.5,
        //   gridWrites = 0, branchCount = 0,
        //   core × 10 = 200 + 45 + 0 + 0 = 245,
        //   factor × 100 = 140,
        //   score × 1000 = 245 × 140 = 34_300,
        //   34_300 ≥ 30_000 ⇒ Silver.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();

        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        assertEq(scoreX1000, 34_300);
        assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.Silver));

        _mintWith(j);
        assertEq(wndy.balanceOf(recipient), REWARD_SILVER);
        assertTrue(minter.consumedNonce(j.nonce));
        assertTrue(minter.consumedProgram(j.programHash));
    }

    function test_Score_BronzeFloor_AtScore10() public {
        // Build a journal that scores exactly 10 × 1000 = 10_000.
        // Pick log2(2) = 1 (max_alive_ips = 2), no other contributions,
        // diversity 0 → factor 1.0, core × 10 = 100, score × 1000 =
        // 100 × 100 = 10_000 ⇒ Bronze.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = 0;
        j.maxAliveIps = 2;
        j.spawnedIps = 0;
        j.gridWrites = 0;
        j.branchCount = 0;
        j.visitedCells = 20;

        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        assertEq(scoreX1000, 10_000);
        assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.Bronze));

        _mintWith(j);
        assertEq(wndy.balanceOf(recipient), REWARD_BRONZE);
    }

    function test_Score_JustBelowBronze_Reverts() public {
        // Same as Bronze-floor but log2(1) = 0 ⇒ core × 10 = 0 ⇒ score 0.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = BIT_STR;
        j.maxAliveIps = 1;
        j.spawnedIps = 0;
        j.gridWrites = 0;
        j.branchCount = 0;
        j.visitedCells = 20;

        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        assertEq(scoreX1000, 0);
        assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.None));

        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);
        vm.expectRevert(abi.encodeWithSelector(ZkExecutionMinterV2.ScoreBelowFloor.selector, uint256(0)));
        minter.mint(seal, journal);

        // Sub-Bronze does not consume nonce/program — miner can retry
        // after densifying the source.
        assertFalse(minter.consumedNonce(j.nonce));
        assertFalse(minter.consumedProgram(j.programHash));
    }

    function test_Score_SilverFloor_AtScore30() public {
        // Build a journal that scores exactly 30 × 1000 = 30_000.
        // max_alive_ips = 8 → log2 = 3, spawned = 0, branch = 0,
        // writes = 0, diversity 0 → factor 100. Core × 10 = 300,
        // score × 1000 = 300 × 100 = 30_000 ⇒ Silver.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = 0;
        j.maxAliveIps = 8;
        j.spawnedIps = 0;
        j.gridWrites = 0;
        j.branchCount = 0;
        j.visitedCells = 50;

        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        assertEq(scoreX1000, 30_000);
        assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.Silver));
    }

    function test_Score_GoldFloor_AtScore70() public {
        // log2(128) = 7 → log2 part contributes 700 to core × 10.
        // No other metrics, diversity 0 ⇒ factor 100. Score × 1000 =
        // 700 × 100 = 70_000 ⇒ Gold.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = 0;
        j.maxAliveIps = 128;
        j.spawnedIps = 0;
        j.gridWrites = 0;
        j.branchCount = 0;
        j.visitedCells = 200;

        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        assertEq(scoreX1000, 70_000);
        assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.Gold));

        _mintWith(j);
        assertEq(wndy.balanceOf(recipient), REWARD_GOLD);
    }

    // -- spam guard tests -------------------------------------------------

    function test_TSpamGuard_ZeroesSpawnedBonus() public {
        // 100 spawned / 100 visited = density 1.0 ⇒ spawned bonus 0.
        // Only the maxAliveIps contribution survives.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = BIT_T;
        j.maxAliveIps = 50;
        j.spawnedIps = 100;
        j.visitedCells = 100;

        // log2(50) = 5 ⇒ core × 10 = 500. Factor = 100 + 8×5 = 140.
        // Score × 1000 = 500 × 140 = 70_000 ⇒ Gold (huge maxAliveIps).
        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        assertEq(scoreX1000, 70_000);
        assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.Gold));
    }

    function test_TSpamGuard_AtBoundary_KeepsBonus() public {
        // spawned * 2 == visited (boundary, NOT > visited) ⇒ bonus survives.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = BIT_T;
        j.maxAliveIps = 50;
        j.spawnedIps = 50;
        j.visitedCells = 100;

        // log2(50)=5 ⇒ 500; spawned bonus = min(50,20)*15 = 300.
        // core × 10 = 800. factor = 140. score = 800 × 140 = 112_000.
        (uint256 score2,) = minter.computeScore(j);
        assertEq(score2, 112_000);
    }

    function test_DiversityOnlySpamScoresZero() public {
        // Hypothetical "huge grid + 10 hard opcodes scattered": diversity
        // bitmap saturates but all other metrics are zero. Multiplied
        // by factor 1 + 41×0.05 = 3.05, the zero core stays zero.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap =
            BIT_T | BIT_P | BIT_G | BIT_IFH | BIT_IFV | BIT_GUST | BIT_CALM | BIT_TURB | BIT_TRAMP | BIT_STR;
        j.maxAliveIps = 1;
        j.spawnedIps = 0;
        j.gridWrites = 0;
        j.branchCount = 0;
        j.visitedCells = 10;

        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        assertEq(scoreX1000, 0);
        assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.None));
    }

    // -- eligibility tests ------------------------------------------------

    function test_VisitedCells_TooFew_Reverts() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.visitedCells = 9;

        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);
        vm.expectRevert(abi.encodeWithSelector(ZkExecutionMinterV2.VisitedCellsOutOfRange.selector, uint64(9)));
        minter.mint(seal, journal);
    }

    function test_VisitedCells_TooMany_Reverts() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.visitedCells = 1501;

        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);
        vm.expectRevert(abi.encodeWithSelector(ZkExecutionMinterV2.VisitedCellsOutOfRange.selector, uint64(1501)));
        minter.mint(seal, journal);
    }

    function test_VisitedCells_AtMin_PassesEligibility() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.visitedCells = 10;
        // Defaults score Silver — `_journalDefaults` keeps the puzzle_hard
        // shape; Silver still holds at the Min boundary.
        _mintWith(j);
        assertEq(wndy.balanceOf(recipient), REWARD_SILVER);
    }

    function test_VisitedCells_AtMax_PassesEligibility() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.visitedCells = 1500;
        _mintWith(j);
        assertEq(wndy.balanceOf(recipient), REWARD_SILVER);
    }

    function test_Replay_SameNonce_DifferentProgram_Reverts() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        _mintWith(j);

        // Reuse the consumed nonce on a different (also fresh) program.
        // The program-dedup gate runs first in the contract, so we
        // sidestep it by submitting a brand-new programHash and let the
        // nonce guard fire on its own.
        j.programHash = bytes32(uint256(0xDEAD));
        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);
        vm.expectRevert(abi.encodeWithSelector(ZkExecutionMinterV2.NonceAlreadyConsumed.selector, j.nonce));
        minter.mint(seal, journal);
    }

    function test_Replay_SameJournal_RevertsOnProgramGuard() public {
        // The program-dedup gate is checked before the nonce-dedup gate,
        // so re-submitting the byte-identical journal returns
        // `ProgramAlreadyConsumed`, not `NonceAlreadyConsumed`. Both
        // mappings end up `true` after the first mint; this just pins
        // the dispatch order.
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        _mintWith(j);

        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);
        vm.expectRevert(
            abi.encodeWithSelector(ZkExecutionMinterV2.ProgramAlreadyConsumed.selector, j.programHash)
        );
        minter.mint(seal, journal);
    }

    function test_DuplicateProgram_FreshNonce_Reverts() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        _mintWith(j);

        // Fresh nonce, same program hash.
        j.nonce = bytes32(uint256(99));
        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);
        vm.expectRevert(
            abi.encodeWithSelector(ZkExecutionMinterV2.ProgramAlreadyConsumed.selector, j.programHash)
        );
        minter.mint(seal, journal);
    }

    function test_DistinctProgramsBothMint() public {
        ZkExecutionMinterV2.WindyJournal memory a = _journalDefaults();
        a.programHash = bytes32(uint256(0xAAAA));
        a.nonce = bytes32(uint256(1));
        ZkExecutionMinterV2.WindyJournal memory b = _journalDefaults();
        b.programHash = bytes32(uint256(0xBBBB));
        b.nonce = bytes32(uint256(2));

        _mintWith(a);
        _mintWith(b);
        assertEq(wndy.balanceOf(recipient), REWARD_SILVER * 2);
    }

    // -- pause / role / cap regression -----------------------------------

    function test_Pause_BlocksMint() public {
        minter.pause();
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);

        vm.expectRevert(); // EnforcedPause()
        minter.mint(seal, journal);
    }

    function test_Unpause_RestoresMint() public {
        minter.pause();
        minter.unpause();
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        _mintWith(j);
        assertEq(wndy.balanceOf(recipient), REWARD_SILVER);
    }

    function test_NonPauserCannotPause() public {
        address stranger = address(0xBEEF);
        vm.prank(stranger);
        vm.expectRevert();
        minter.pause();
    }

    function test_AdminCanGrantPauserRole() public {
        address operator = address(0xCAFE);
        minter.grantRole(minter.PAUSER_ROLE(), operator);
        vm.prank(operator);
        minter.pause();
        assertTrue(minter.paused());
    }

    function test_NoMinterRole_Reverts() public {
        ZkExecutionMinterV2 rogue = new ZkExecutionMinterV2(
            mockVerifier, wndy, IMAGE_ID, REWARD_BRONZE, REWARD_SILVER, REWARD_GOLD
        );
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);

        vm.expectRevert();
        rogue.mint(seal, journal);
    }

    function test_RewardOverCap_Reverts() public {
        uint256 cap = wndy.MAX_SUPPLY();
        ZkExecutionMinterV2 bigMinter = new ZkExecutionMinterV2(
            mockVerifier, wndy, IMAGE_ID, REWARD_BRONZE, REWARD_SILVER, cap + 1
        );
        wndy.grantRole(wndy.MINTER_ROLE(), address(bigMinter));

        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.maxAliveIps = 128;
        j.spawnedIps = 0;
        j.hardOpcodeBitmap = 0;
        j.visitedCells = 200;

        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);
        vm.expectRevert(abi.encodeWithSelector(Windy.MaxSupplyExceeded.selector, cap + 1, cap));
        bigMinter.mint(seal, journal);
    }

    function test_BadSeal_Reverts() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        bytes memory journal = _encode(j);
        bytes memory badSeal = hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

        vm.expectRevert();
        minter.mint(badSeal, journal);

        assertFalse(minter.consumedNonce(j.nonce));
        assertFalse(minter.consumedProgram(j.programHash));
    }

    function test_TamperedJournal_Reverts() public {
        ZkExecutionMinterV2.WindyJournal memory a = _journalDefaults();
        ZkExecutionMinterV2.WindyJournal memory b = _journalDefaults();
        b.nonce = bytes32(uint256(99));

        bytes memory journalA = _encode(a);
        bytes memory journalB = _encode(b);
        bytes memory sealForA = _mockProve(journalA);

        vm.expectRevert();
        minter.mint(sealForA, journalB);
    }

    // -- emit verification ------------------------------------------------

    function test_Mint_EmitsMintedWithFullJournal() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        bytes memory journal = _encode(j);
        bytes memory seal = _mockProve(journal);

        vm.expectEmit(true, true, false, true, address(minter));
        emit Minted(
            j.recipient,
            j.nonce,
            j.programHash,
            j.outputHash,
            j.exitCode,
            j.steps,
            j.visitedCells,
            uint256(34_300),
            ZkExecutionMinterV2.Tier.Silver,
            REWARD_SILVER
        );
        minter.mint(seal, journal);
    }

    // -- fuzz tests -------------------------------------------------------
    //
    // computeScore is pure, so we fuzz it directly without any prover or
    // chain interaction. The bound on `visitedCells` matches the contract's
    // eligibility window so we exercise the in-bounds path; out-of-bounds
    // values are covered by the explicit revert tests above.

    /// @dev Score must never exceed a static upper bound regardless of
    /// metric inputs. Concretely: every metric is capped, the diversity
    /// factor is capped at 100 + 41×5 = 305, and core×10 is capped at
    /// log2(2^64-1)×100 + 20×15 + 100×3 + 100×2 = 6300 + 300 + 300 + 200
    /// = 7100. Score×1000 ≤ 7100 × 305 = 2_165_500. Anything beyond that
    /// would mean a clamp regressed.
    function testFuzz_ScoreNeverExceedsUpperBound(
        uint16 hardOpcodeBitmap,
        uint64 maxAliveIps,
        uint64 spawnedIps,
        uint64 gridWrites,
        uint64 branchCount,
        uint64 visitedCells
    ) public view {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = hardOpcodeBitmap;
        j.maxAliveIps = maxAliveIps;
        j.spawnedIps = spawnedIps;
        j.gridWrites = gridWrites;
        j.branchCount = branchCount;
        j.visitedCells = visitedCells;

        (uint256 scoreX1000,) = minter.computeScore(j);
        assertLe(scoreX1000, 2_165_500);
    }

    /// @dev Score is monotonically non-decreasing in `gridWrites` (with
    /// every other input held). All four `core` summands are added, not
    /// xored, and `gridWrites` only contributes positively until its cap.
    /// Past the cap (>100) the contribution is constant so the property
    /// still holds with `assertGe`.
    function testFuzz_ScoreMonotonicInGridWrites(uint64 a, uint64 b) public view {
        vm.assume(a < b);
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();

        j.gridWrites = a;
        (uint256 scoreA,) = minter.computeScore(j);
        j.gridWrites = b;
        (uint256 scoreB,) = minter.computeScore(j);

        assertGe(scoreB, scoreA);
    }

    /// @dev Same monotonicity over `branchCount`.
    function testFuzz_ScoreMonotonicInBranches(uint64 a, uint64 b) public view {
        vm.assume(a < b);
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();

        j.branchCount = a;
        (uint256 scoreA,) = minter.computeScore(j);
        j.branchCount = b;
        (uint256 scoreB,) = minter.computeScore(j);

        assertGe(scoreB, scoreA);
    }

    /// @dev Diversity is multiplicative; with `core == 0` (no other
    /// metrics) any setting of the bitmap multiplies zero by 1.0–3.05 and
    /// must stay zero. This pins the "huge-grid spam" guarantee from the
    /// design spec.
    function testFuzz_DiversityOnlyAlwaysScoresZero(uint16 hardOpcodeBitmap) public view {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = hardOpcodeBitmap;
        j.maxAliveIps = 1; // log2 = 0
        j.spawnedIps = 0;
        j.gridWrites = 0;
        j.branchCount = 0;
        j.visitedCells = 100; // arbitrary, in-range

        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        assertEq(scoreX1000, 0);
        assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.None));
    }

    /// @dev When 2 × spawnedIps > visitedCells, the spawned-bonus
    /// contribution must be zero. The t-spam guard is what prevents a
    /// long SPLIT chain from hitting Silver/Gold via spawned-count alone.
    /// We isolate the bonus by zeroing every other input.
    function testFuzz_TSpamGuardKillsSpawnedBonus(
        uint64 spawnedIps,
        uint64 visitedCells
    ) public view {
        spawnedIps = uint64(bound(spawnedIps, 1, 1000));
        visitedCells = uint64(bound(visitedCells, 10, 1500));
        vm.assume(uint256(spawnedIps) * 2 > uint256(visitedCells));

        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = 0;
        j.maxAliveIps = 1; // log2 = 0 → no maxAliveIps contribution
        j.spawnedIps = spawnedIps;
        j.gridWrites = 0;
        j.branchCount = 0;
        j.visitedCells = visitedCells;

        (uint256 scoreX1000,) = minter.computeScore(j);
        // With every contribution zero (spawned bonus killed by guard,
        // log2(1)=0, no writes, no branches), the score must be zero.
        assertEq(scoreX1000, 0);
    }

    /// @dev When 2 × spawnedIps ≤ visitedCells, the bonus survives. We
    /// pick visitedCells just at the boundary so the inequality flips
    /// exactly between cases.
    function testFuzz_SpawnedBonusSurvivesUnderTSpamCutoff(uint64 spawnedIps) public view {
        spawnedIps = uint64(bound(spawnedIps, 1, 20));
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        j.hardOpcodeBitmap = 0;
        j.maxAliveIps = 1;
        j.spawnedIps = spawnedIps;
        j.gridWrites = 0;
        j.branchCount = 0;
        j.visitedCells = uint64(uint256(spawnedIps) * 2); // boundary: ratio = 0.5 exactly, NOT >0.5

        (uint256 scoreX1000,) = minter.computeScore(j);
        // Bonus = spawnedIps × 15 (since spawnedIps ≤ 20 = CAP), factor = 100.
        assertEq(scoreX1000, uint256(spawnedIps) * 15 * 100);
    }

    /// @dev Tier-dispatch boundaries are stable: if score increases, tier
    /// is non-decreasing. Pin a few specific scores at the cutoffs.
    function testFuzz_TierDispatchAtBoundaries(uint256 scoreNudge) public view {
        scoreNudge = bound(scoreNudge, 0, 99_999);
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();

        // Drive score by setting branches × 0.2 (×10 = ×2). Each unit of
        // branchCount adds 200 to scoreX1000 (factor = 100). So
        // branchCount = 50 → scoreX1000 = 10_000 (Bronze floor).
        j.hardOpcodeBitmap = 0;
        j.maxAliveIps = 1;
        j.spawnedIps = 0;
        j.gridWrites = 0;
        j.visitedCells = 100;
        j.branchCount = uint64(scoreNudge / 200);

        (uint256 scoreX1000, ZkExecutionMinterV2.Tier tier) = minter.computeScore(j);
        if (scoreX1000 < 10_000) assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.None));
        else if (scoreX1000 < 30_000) assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.Bronze));
        else if (scoreX1000 < 70_000) assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.Silver));
        else assertEq(uint256(tier), uint256(ZkExecutionMinterV2.Tier.Gold));
    }

    // -- invariants -------------------------------------------------------

    /// @dev Once a nonce is consumed, it stays consumed. This is a
    /// per-mint property covered by `consumedNonce()` — we just pin that
    /// no code path resets it.
    function test_ConsumedNonceIsPermanent() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        _mintWith(j);
        assertTrue(minter.consumedNonce(j.nonce));

        // Pause and unpause — neither must clear consumedNonce.
        minter.pause();
        minter.unpause();
        assertTrue(minter.consumedNonce(j.nonce));
    }

    /// @dev Same, for consumedProgram.
    function test_ConsumedProgramIsPermanent() public {
        ZkExecutionMinterV2.WindyJournal memory j = _journalDefaults();
        _mintWith(j);
        assertTrue(minter.consumedProgram(j.programHash));

        minter.pause();
        minter.unpause();
        assertTrue(minter.consumedProgram(j.programHash));
    }

    /// @dev totalSupply increments by exactly the tier reward on each
    /// successful mint, never more. We exercise each tier by rebuilding
    /// minimal journals with hand-tuned metrics.
    function test_TotalSupplyMatchesTierRewards() public {
        // Mint Silver (default journal hits Silver).
        _mintWith(_journalDefaults());

        // Mint Bronze: distinct program, score in [10, 30) — set
        // maxAliveIps = 2 alone (log2=1, ×100 = 100 → core×10 = 100,
        // factor 100 → score = 10_000 → Bronze).
        ZkExecutionMinterV2.WindyJournal memory bronze = _journalDefaults();
        bronze.programHash = bytes32(uint256(0xCAFE));
        bronze.nonce = bytes32(uint256(2));
        bronze.hardOpcodeBitmap = 0;
        bronze.maxAliveIps = 2;
        bronze.spawnedIps = 0;
        _mintWith(bronze);

        // Mint Gold: distinct program, score ≥ 70.
        ZkExecutionMinterV2.WindyJournal memory gold = _journalDefaults();
        gold.programHash = bytes32(uint256(0xBABE));
        gold.nonce = bytes32(uint256(3));
        gold.hardOpcodeBitmap = 0;
        gold.maxAliveIps = 128; // log2 = 7
        gold.spawnedIps = 0;
        _mintWith(gold);

        assertEq(wndy.totalSupply(), REWARD_SILVER + REWARD_BRONZE + REWARD_GOLD);
        assertEq(wndy.balanceOf(recipient), REWARD_SILVER + REWARD_BRONZE + REWARD_GOLD);
    }
}
