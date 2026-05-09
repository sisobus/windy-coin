// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {Windy} from "../src/Windy.sol";
import {ZkExecutionMinterV2} from "../src/ZkExecutionMinterV2.sol";

/// @notice Mainnet deploy: a single broadcast that deploys `Windy`
///         and `ZkExecutionMinterV2`, grants `MINTER_ROLE` on the
///         token to the minter, *and* immediately hands every admin
///         role to a pre-existing multisig. The EOA that runs this
///         script is privileged for exactly the duration of the
///         four-tx broadcast and never afterwards.
/// @dev    Differs from `DeployV2.s.sol` in two ways: there's no V1
///         to retire (mainnet starts from a clean slate), and the
///         deployer EOA renounces every role at the end of the same
///         broadcast — so the testnet pattern of "EOA → later
///         multisig migration" collapses into one atomic deploy.
/// @dev Reads from environment:
///   VERIFIER       (address) — IRiscZeroVerifier (Base mainnet router
///                              `0x0b144e07a0826182b6b59788c34b32bfa86fb711`)
///   IMAGE_ID       (bytes32) — Phase 2 guest ELF digest pinned in the repo
///                              (must come from `cargo run -p host -- --print-image-id`
///                              after `cargo build --locked` so the
///                              committed `Cargo.lock` controls it)
///   REWARD_BRONZE  (uint256) — base units (1e17 = 0.1 WNDY)
///   REWARD_SILVER  (uint256) — base units (1e18 = 1 WNDY)
///   REWARD_GOLD    (uint256) — base units (1e19 = 10 WNDY, also per-proof cap)
///   MULTISIG       (address) — Safe (or equivalent) that owns the
///                              token's `DEFAULT_ADMIN_ROLE` and the
///                              minter's `DEFAULT_ADMIN_ROLE` +
///                              `PAUSER_ROLE` from this block on.
///
/// Run with (using a hardware wallet on Ledger):
///   forge script script/DeployMainnet.s.sol:DeployMainnet \
///     --rpc-url $BASE_MAINNET_RPC \
///     --ledger --hd-paths "m/44'/60'/0'/0/0" \
///     --broadcast --verify
contract DeployMainnet is Script {
    function run() external returns (Windy wndy, ZkExecutionMinterV2 minter) {
        address verifier = vm.envAddress("VERIFIER");
        bytes32 imageId = vm.envBytes32("IMAGE_ID");
        uint256 rewardBronze = vm.envUint("REWARD_BRONZE");
        uint256 rewardSilver = vm.envUint("REWARD_SILVER");
        uint256 rewardGold = vm.envUint("REWARD_GOLD");
        address multisig = vm.envAddress("MULTISIG");

        bytes32 adminRole = 0x00; // DEFAULT_ADMIN_ROLE

        vm.startBroadcast();

        // 1. Deploy the token.
        wndy = new Windy();

        // 2. Deploy V2 minter.
        minter = new ZkExecutionMinterV2(
            IRiscZeroVerifier(verifier),
            wndy,
            imageId,
            rewardBronze,
            rewardSilver,
            rewardGold
        );

        // 3. Wire the only minting path.
        wndy.grantRole(wndy.MINTER_ROLE(), address(minter));

        // 4. Hand admin + pauser to the multisig immediately.
        bytes32 pauserRole = minter.PAUSER_ROLE();
        wndy.grantRole(adminRole, multisig);
        minter.grantRole(adminRole, multisig);
        minter.grantRole(pauserRole, multisig);

        // 5. Drop the deployer EOA's privileges. After this, the EOA
        //    is no different from any other address; only the
        //    multisig can grant new minters or pause.
        wndy.renounceRole(adminRole, msg.sender);
        minter.renounceRole(adminRole, msg.sender);
        minter.renounceRole(pauserRole, msg.sender);

        vm.stopBroadcast();

        console.log("Windy:                  ", address(wndy));
        console.log("ZkExecutionMinterV2:    ", address(minter));
        console.log("MULTISIG (admin/pauser):", multisig);
        console.log("VERIFIER (router):      ", verifier);
        console.log("REWARD_BRONZE:          ", rewardBronze);
        console.log("REWARD_SILVER:          ", rewardSilver);
        console.log("REWARD_GOLD:            ", rewardGold);
        console.log("IMAGE_ID:");
        console.logBytes32(imageId);
    }
}
