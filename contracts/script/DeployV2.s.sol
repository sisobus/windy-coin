// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {Windy} from "../src/Windy.sol";
import {ZkExecutionMinter} from "../src/ZkExecutionMinter.sol";
import {ZkExecutionMinterV2} from "../src/ZkExecutionMinterV2.sol";

/// @notice One-shot Phase 2 migration: deploy V2, swap MINTER_ROLE
///         from V1 to V2, then pause V1. Requires the deployer to hold
///         DEFAULT_ADMIN_ROLE on `Windy` and PAUSER_ROLE on the V1 minter
///         — typically the same EOA that deployed Phase 1.5.
/// @dev Reads from environment:
///   VERIFIER       (address) — IRiscZeroVerifier (router)
///   WNDY           (address) — existing Windy token (Phase 1.5's deploy)
///   V1_MINTER      (address) — Phase 1.5 ZkExecutionMinter being retired
///   IMAGE_ID       (bytes32) — Phase 2 guest ELF digest
///   REWARD_BRONZE  (uint256) — base units (1e17 = 0.1 WNDY)
///   REWARD_SILVER  (uint256) — base units (1e18 = 1 WNDY)
///   REWARD_GOLD    (uint256) — base units (1e19 = 10 WNDY)
///
/// Run with:
///   forge script script/DeployV2.s.sol:DeployV2 \
///     --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
contract DeployV2 is Script {
    function run() external returns (ZkExecutionMinterV2 minter) {
        address verifier = vm.envAddress("VERIFIER");
        address wndyAddr = vm.envAddress("WNDY");
        address v1Minter = vm.envAddress("V1_MINTER");
        bytes32 imageId = vm.envBytes32("IMAGE_ID");
        uint256 rewardBronze = vm.envUint("REWARD_BRONZE");
        uint256 rewardSilver = vm.envUint("REWARD_SILVER");
        uint256 rewardGold = vm.envUint("REWARD_GOLD");

        Windy wndy = Windy(wndyAddr);
        ZkExecutionMinter v1 = ZkExecutionMinter(v1Minter);
        bytes32 minterRole = wndy.MINTER_ROLE();

        vm.startBroadcast();

        // 1. Deploy the V2 minter.
        minter = new ZkExecutionMinterV2(
            IRiscZeroVerifier(verifier),
            wndy,
            imageId,
            rewardBronze,
            rewardSilver,
            rewardGold
        );

        // 2. Grant MINTER_ROLE to V2.
        wndy.grantRole(minterRole, address(minter));

        // 3. Revoke MINTER_ROLE from V1 — V1 can no longer mint after
        // this point. The token holders see no change; the only effect
        // is that V1.mint() will revert at WNDY.mint() with an
        // AccessControl error.
        wndy.revokeRole(minterRole, v1Minter);

        // 4. Pause V1 explicitly so stale tooling submitting against
        // the V1 ABI gets a clean revert at the V1 contract instead of
        // at the WNDY token. This is belt-and-suspenders — step 3 is
        // already enough to make V1 useless — but it leaves an
        // unambiguous "this minter is retired" signal on chain.
        v1.pause();

        vm.stopBroadcast();

        console.log("ZkExecutionMinterV2:    ", address(minter));
        console.log("WNDY (existing):        ", wndyAddr);
        console.log("V1 minter (retired):    ", v1Minter);
        console.log("VERIFIER (router):      ", verifier);
        console.log("REWARD_BRONZE:          ", rewardBronze);
        console.log("REWARD_SILVER:          ", rewardSilver);
        console.log("REWARD_GOLD:            ", rewardGold);
        console.log("IMAGE_ID:");
        console.logBytes32(imageId);
    }
}
