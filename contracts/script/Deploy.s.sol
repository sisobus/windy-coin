// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {Windy} from "../src/Windy.sol";
import {ZkExecutionMinter} from "../src/ZkExecutionMinter.sol";

/// @notice Deploys Windy and a ZkExecutionMinter, then grants `MINTER_ROLE`
///         on the token to the minter.
/// @dev Reads three environment variables:
///   VERIFIER  — `IRiscZeroVerifier` address. On Base Sepolia, the canonical
///               choice is the Risc Zero router at
///               0x0b144e07a0826182b6b59788c34b32bfa86fb711.
///   IMAGE_ID  — `bytes32` of the windy-coin guest ELF. Produce with:
///                 cargo run -p host -- --print-image-id
///   REWARD    — fixed mint per accepted proof, in base units (1e18 = 1 WNDY).
///
/// Run with:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
contract Deploy is Script {
    function run() external returns (Windy wndy, ZkExecutionMinter minter) {
        address verifier = vm.envAddress("VERIFIER");
        bytes32 imageId = vm.envBytes32("IMAGE_ID");
        uint256 reward = vm.envUint("REWARD");

        vm.startBroadcast();
        wndy = new Windy();
        minter = new ZkExecutionMinter(
            IRiscZeroVerifier(verifier),
            wndy,
            imageId,
            reward
        );
        wndy.grantRole(wndy.MINTER_ROLE(), address(minter));
        vm.stopBroadcast();

        console.log("Windy deployed:                ", address(wndy));
        console.log("ZkExecutionMinter deployed:    ", address(minter));
        console.log("VERIFIER (router):             ", verifier);
        console.log("REWARD (base units):           ", reward);
        console.log("IMAGE_ID:");
        console.logBytes32(imageId);
    }
}
