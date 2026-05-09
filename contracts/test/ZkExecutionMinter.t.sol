// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Windy} from "../src/Windy.sol";
import {ZkExecutionMinter} from "../src/ZkExecutionMinter.sol";
import {RiscZeroMockVerifier} from "risc0/test/RiscZeroMockVerifier.sol";
import {Receipt as RiscZeroReceipt} from "risc0/IRiscZeroVerifier.sol";

contract ZkExecutionMinterTest is Test {
    Windy public wndy;
    ZkExecutionMinter public minter;
    RiscZeroMockVerifier public mockVerifier;

    bytes32 public constant IMAGE_ID = bytes32(uint256(0xbeef));
    bytes4 public constant SELECTOR = bytes4(0x12345678);
    uint256 public constant REWARD = 1e18;

    address public recipient = address(0xC0FFEE);

    event Minted(
        address indexed recipient,
        bytes32 indexed nonce,
        bytes32 programHash,
        bytes32 outputHash,
        int32 exitCode,
        uint64 steps,
        uint256 amount
    );

    function setUp() public {
        wndy = new Windy();
        mockVerifier = new RiscZeroMockVerifier(SELECTOR);
        minter = new ZkExecutionMinter(mockVerifier, wndy, IMAGE_ID, REWARD);
        wndy.grantRole(wndy.MINTER_ROLE(), address(minter));
    }

    function _buildJournal(bytes32 nonce) internal view returns (bytes memory) {
        ZkExecutionMinter.WindyJournal memory j = ZkExecutionMinter.WindyJournal({
            recipient: recipient,
            nonce: nonce,
            programHash: bytes32(uint256(0x1111)),
            outputHash: bytes32(uint256(0x2222)),
            exitCode: int32(0),
            steps: uint64(29)
        });
        return abi.encode(j);
    }

    function _mockProve(bytes memory journal) internal view returns (bytes memory seal) {
        bytes32 digest = sha256(journal);
        RiscZeroReceipt memory r = mockVerifier.mockProve(IMAGE_ID, digest);
        return r.seal;
    }

    function test_Mint_HappyPath() public {
        bytes32 nonce = bytes32(uint256(1));
        bytes memory journal = _buildJournal(nonce);
        bytes memory seal = _mockProve(journal);

        vm.expectEmit(true, true, false, true, address(minter));
        emit Minted(
            recipient,
            nonce,
            bytes32(uint256(0x1111)),
            bytes32(uint256(0x2222)),
            int32(0),
            uint64(29),
            REWARD
        );

        minter.mint(seal, journal);

        assertEq(wndy.balanceOf(recipient), REWARD);
        assertTrue(minter.consumedNonce(nonce));
        assertEq(wndy.totalSupply(), REWARD);
    }

    function test_Mint_DistinctNoncesBothSucceed() public {
        bytes memory j1 = _buildJournal(bytes32(uint256(1)));
        bytes memory j2 = _buildJournal(bytes32(uint256(2)));

        minter.mint(_mockProve(j1), j1);
        minter.mint(_mockProve(j2), j2);

        assertEq(wndy.balanceOf(recipient), REWARD * 2);
    }

    function test_Replay_Reverts() public {
        bytes32 nonce = bytes32(uint256(42));
        bytes memory journal = _buildJournal(nonce);
        bytes memory seal = _mockProve(journal);

        minter.mint(seal, journal);

        vm.expectRevert(abi.encodeWithSelector(ZkExecutionMinter.NonceAlreadyConsumed.selector, nonce));
        minter.mint(seal, journal);

        assertEq(wndy.balanceOf(recipient), REWARD);
    }

    function test_BadSeal_Reverts() public {
        bytes32 nonce = bytes32(uint256(7));
        bytes memory journal = _buildJournal(nonce);
        // Garbage seal: doesn't carry the right SELECTOR / claimDigest pair.
        bytes memory badSeal = hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

        vm.expectRevert();
        minter.mint(badSeal, journal);

        assertFalse(minter.consumedNonce(nonce));
        assertEq(wndy.balanceOf(recipient), 0);
    }

    function test_TamperedJournal_Reverts() public {
        // Build a valid proof for one journal, then submit it with a
        // different journal — the seal won't match the new digest.
        bytes memory journalA = _buildJournal(bytes32(uint256(11)));
        bytes memory journalB = _buildJournal(bytes32(uint256(22)));
        bytes memory sealForA = _mockProve(journalA);

        vm.expectRevert();
        minter.mint(sealForA, journalB);
    }

    function test_NoMinterRole_Reverts() public {
        ZkExecutionMinter rogueMinter =
            new ZkExecutionMinter(mockVerifier, wndy, IMAGE_ID, REWARD);
        bytes memory journal = _buildJournal(bytes32(uint256(99)));
        bytes memory seal = _mockProve(journal);

        vm.expectRevert();
        rogueMinter.mint(seal, journal);
    }

    function test_RewardOverCap_Reverts() public {
        uint256 cap = wndy.MAX_SUPPLY();
        ZkExecutionMinter bigMinter =
            new ZkExecutionMinter(mockVerifier, wndy, IMAGE_ID, cap + 1);
        wndy.grantRole(wndy.MINTER_ROLE(), address(bigMinter));

        bytes memory journal = _buildJournal(bytes32(uint256(123)));
        bytes memory seal = _mockProve(journal);

        vm.expectRevert(
            abi.encodeWithSelector(Windy.MaxSupplyExceeded.selector, cap + 1, cap)
        );
        bigMinter.mint(seal, journal);
    }

    function test_Pause_BlocksMint() public {
        bytes memory journal = _buildJournal(bytes32(uint256(7)));
        bytes memory seal = _mockProve(journal);

        minter.pause();
        assertTrue(minter.paused());

        // OZ Pausable reverts with `EnforcedPause()`.
        vm.expectRevert();
        minter.mint(seal, journal);

        // Same nonce was never consumed — recipient balance still 0.
        assertFalse(minter.consumedNonce(bytes32(uint256(7))));
        assertEq(wndy.balanceOf(recipient), 0);
    }

    function test_Unpause_RestoresMint() public {
        minter.pause();
        minter.unpause();
        assertFalse(minter.paused());

        bytes memory journal = _buildJournal(bytes32(uint256(8)));
        minter.mint(_mockProve(journal), journal);
        assertEq(wndy.balanceOf(recipient), REWARD);
    }

    function test_NonPauser_CannotPause() public {
        address stranger = address(0xBEEF);
        vm.prank(stranger);
        // OZ AccessControl reverts with `AccessControlUnauthorizedAccount(...)`.
        vm.expectRevert();
        minter.pause();

        assertFalse(minter.paused());
    }

    function test_AdminCanGrantPauserRole() public {
        address operator = address(0xCAFE);
        minter.grantRole(minter.PAUSER_ROLE(), operator);

        vm.prank(operator);
        minter.pause();
        assertTrue(minter.paused());
    }
}
