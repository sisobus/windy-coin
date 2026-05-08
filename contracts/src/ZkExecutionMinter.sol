// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {Windy} from "./Windy.sol";

/// @notice Phase 1 free-mint minter for the WNDY token.
/// @dev Anyone holding a Risc Zero proof of windy-lang execution against
///      `IMAGE_ID` can mint `REWARD` WNDY to the recipient committed in
///      the journal. Replay is prevented by tracking the per-proof nonce
///      (also committed in the journal). Mining-policy upgrades — exit
///      code gating, output-hash difficulty, challenge-response — layer
///      on top in later phases via additional minter contracts that
///      receive `MINTER_ROLE` independently.
contract ZkExecutionMinter {
    /// @notice Layout MUST match `WindyJournalSol` in
    /// `circuit/core/src/lib.rs`. The guest commits the abi-encoded
    /// bytes of that struct, and the verifier binds the proof to
    /// `sha256(journal)` — so any field swap or re-ordering would
    /// either break the verifier check or decode into garbage.
    struct WindyJournal {
        address recipient;
        bytes32 nonce;
        bytes32 programHash;
        bytes32 outputHash;
        int32 exitCode;
        uint64 steps;
    }

    /// @notice The Risc Zero on-chain verifier (typically the chain's
    /// `RiscZeroVerifierRouter`, but any `IRiscZeroVerifier` works).
    IRiscZeroVerifier public immutable VERIFIER;

    /// @notice The WNDY token contract this minter mints into.
    Windy public immutable WNDY;

    /// @notice The image ID of the windy-coin guest binary. Pinning
    /// this means a guest source change ⇒ a new minter deployment.
    bytes32 public immutable IMAGE_ID;

    /// @notice Fixed reward per accepted proof, in WNDY base units (1e18 = 1 WNDY).
    uint256 public immutable REWARD;

    /// @notice Tracks consumed proof nonces to reject replays.
    mapping(bytes32 => bool) public consumedNonce;

    error NonceAlreadyConsumed(bytes32 nonce);

    event Minted(
        address indexed recipient,
        bytes32 indexed nonce,
        bytes32 programHash,
        bytes32 outputHash,
        int32 exitCode,
        uint64 steps,
        uint256 amount
    );

    constructor(IRiscZeroVerifier verifier, Windy wndy, bytes32 imageId, uint256 reward) {
        VERIFIER = verifier;
        WNDY = wndy;
        IMAGE_ID = imageId;
        REWARD = reward;
    }

    /// @notice Verify a windy-lang execution proof and mint the reward.
    /// @param seal     Risc Zero seal bytes (the receipt's seal).
    /// @param journal  ABI-encoded `WindyJournal` — exactly the bytes
    ///                 the guest committed via `env::commit_slice`.
    function mint(bytes calldata seal, bytes calldata journal) external {
        bytes32 journalDigest = sha256(journal);
        VERIFIER.verify(seal, IMAGE_ID, journalDigest);

        WindyJournal memory j = abi.decode(journal, (WindyJournal));

        if (consumedNonce[j.nonce]) revert NonceAlreadyConsumed(j.nonce);
        consumedNonce[j.nonce] = true;

        WNDY.mint(j.recipient, REWARD);
        emit Minted(
            j.recipient,
            j.nonce,
            j.programHash,
            j.outputHash,
            j.exitCode,
            j.steps,
            REWARD
        );
    }
}
