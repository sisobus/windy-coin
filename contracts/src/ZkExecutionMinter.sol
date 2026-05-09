// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {Windy} from "./Windy.sol";

/// @title  ZkExecutionMinter — Phase 1 free-mint minter for the WNDY token
/// @notice Anyone holding a Risc Zero proof of windy-lang execution against
///         this minter's pinned `IMAGE_ID` can mint `REWARD` WNDY to the
///         `recipient` committed inside the proof's journal.
/// @dev    Replay protection comes from `consumedNonce`, keyed off the
///         per-proof `nonce` field that the guest commits inside the
///         abi-encoded journal. The proof binds (recipient, nonce, …) — any
///         tampering with the journal bytes breaks the verifier's
///         `sha256(journal)` digest check, so a third party who obtains the
///         seal cannot redirect the mint.
///
///         Phase 1's mint policy is intentionally permissive ("any valid
///         proof of any windy program → 1 WNDY"). Real mining policies
///         (output-hash difficulty, step-count gating, challenge-response,
///         …) ship in Phase 2 as *separate* minter contracts. Each new
///         minter is wired in by granting it `MINTER_ROLE` on `Windy`; the
///         Phase 1 minter can be retired by revoking that role and/or
///         calling `pause()` on this contract.
///
///         Roles:
///           - `DEFAULT_ADMIN_ROLE` — granted to the deployer at
///             construction. May grant/revoke `PAUSER_ROLE`.
///           - `PAUSER_ROLE` — granted to the deployer at construction.
///             May call `pause()` / `unpause()` to halt new mints in case a
///             vulnerability is discovered. Pausing only affects this
///             contract; `Windy` itself is untouched, so the 21M cap and
///             holder balances stay intact regardless.
contract ZkExecutionMinter is AccessControl, Pausable {
    /// @notice Address authorized to call `pause()` / `unpause()`.
    /// @dev Computed as `keccak256("PAUSER_ROLE")`.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Layout MUST match `WindyJournalSol` in
    ///         `circuit/core/src/lib.rs`. The guest commits the abi-encoded
    ///         bytes of that struct, and the verifier binds the proof to
    ///         `sha256(journal)` — so any field swap or re-ordering would
    ///         either break the verifier check or decode into garbage.
    struct WindyJournal {
        address recipient;
        bytes32 nonce;
        bytes32 programHash;
        bytes32 outputHash;
        int32 exitCode;
        uint64 steps;
    }

    /// @notice The Risc Zero on-chain verifier (typically the chain's
    ///         `RiscZeroVerifierRouter`, but any `IRiscZeroVerifier` works).
    IRiscZeroVerifier public immutable VERIFIER;

    /// @notice The WNDY token contract this minter mints into. Must have
    ///         granted `MINTER_ROLE` to this contract for `mint()` to
    ///         succeed.
    Windy public immutable WNDY;

    /// @notice The image ID of the windy-coin guest binary. Pinning this
    ///         means a guest source change ⇒ a new minter deployment.
    bytes32 public immutable IMAGE_ID;

    /// @notice Fixed reward per accepted proof, in WNDY base units
    ///         (`1e18` = 1 WNDY).
    uint256 public immutable REWARD;

    /// @notice Set to `true` once the corresponding journal nonce has been
    ///         consumed by a successful mint. Re-submission of the same
    ///         (seal, journal) pair — or any other proof carrying the same
    ///         nonce — reverts with `NonceAlreadyConsumed`.
    mapping(bytes32 => bool) public consumedNonce;

    /// @notice Reverted when `mint` receives a journal whose nonce has
    ///         already been used by a previous successful mint.
    error NonceAlreadyConsumed(bytes32 nonce);

    /// @notice Emitted on a successful mint. Carries the full decoded
    ///         journal so off-chain indexers can reconstruct what was
    ///         proved without re-decoding the calldata.
    /// @param recipient    Address that received the freshly minted WNDY.
    /// @param nonce        Proof-bound nonce (also written to
    ///                     `consumedNonce` to prevent replay).
    /// @param programHash  `sha256` of the windy-lang source the guest
    ///                     executed.
    /// @param outputHash   `sha256` of the windy program's stdout.
    /// @param exitCode     Guest VM exit code (0 = Ok, 124 = MaxSteps,
    ///                     134 = Trap).
    /// @param steps        Number of windy VM ticks consumed by the run.
    /// @param amount       WNDY base units minted to `recipient` (always
    ///                     equal to `REWARD` in Phase 1).
    event Minted(
        address indexed recipient,
        bytes32 indexed nonce,
        bytes32 programHash,
        bytes32 outputHash,
        int32 exitCode,
        uint64 steps,
        uint256 amount
    );

    /// @param verifier `IRiscZeroVerifier` to delegate proof verification to.
    /// @param wndy     `Windy` token. The deployer is responsible for
    ///                 granting `MINTER_ROLE` on `wndy` to this contract.
    /// @param imageId  Guest ELF digest the verifier will require.
    /// @param reward   Fixed payout per accepted proof, in WNDY base units.
    constructor(IRiscZeroVerifier verifier, Windy wndy, bytes32 imageId, uint256 reward) {
        VERIFIER = verifier;
        WNDY = wndy;
        IMAGE_ID = imageId;
        REWARD = reward;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    /// @notice Halt new mints. Existing balances and the 21M cap are
    ///         unaffected — this only blocks `mint()`.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume new mints.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Verify a windy-lang execution proof and mint the reward.
    /// @dev Call order matches Checks-Effects-Interactions: verify the
    ///      proof, decode the journal, mark the nonce consumed, emit the
    ///      event, then make the only mutating external call (to
    ///      `WNDY.mint`). `WNDY` is our own ERC-20 (no recipient hooks),
    ///      and `VERIFIER.verify` is declared `view`, so neither external
    ///      call can re-enter this function — the CEI ordering is for
    ///      readability and audit hygiene rather than to defend against a
    ///      live re-entrancy vector.
    /// @param seal     Risc Zero seal bytes (the receipt's seal).
    /// @param journal  ABI-encoded `WindyJournal` — exactly the bytes the
    ///                 guest committed via `env::commit_slice`.
    function mint(bytes calldata seal, bytes calldata journal) external whenNotPaused {
        bytes32 journalDigest = sha256(journal);
        VERIFIER.verify(seal, IMAGE_ID, journalDigest);

        WindyJournal memory j = abi.decode(journal, (WindyJournal));

        if (consumedNonce[j.nonce]) revert NonceAlreadyConsumed(j.nonce);
        consumedNonce[j.nonce] = true;

        emit Minted(
            j.recipient,
            j.nonce,
            j.programHash,
            j.outputHash,
            j.exitCode,
            j.steps,
            REWARD
        );

        WNDY.mint(j.recipient, REWARD);
    }
}
