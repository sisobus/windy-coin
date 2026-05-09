// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Windy} from "../src/Windy.sol";
import {ZkExecutionMinterV2} from "../src/ZkExecutionMinterV2.sol";

/// @notice Hand admin and pauser authority over to a multisig (Safe,
///         typically) and revoke the deploying EOA's roles. Run this
///         from the EOA that currently holds those roles.
/// @dev    Touches three role assignments in one broadcast:
///           1. grant `DEFAULT_ADMIN_ROLE` on `Windy` to the multisig
///           2. grant `DEFAULT_ADMIN_ROLE` + `PAUSER_ROLE` on the
///              minter to the multisig
///           3. EOA renounces both roles on both contracts (so the
///              EOA can no longer mutate state)
///
///         After this script runs successfully:
///           - Adding a new minter (e.g. Phase 3 halving / known-algo
///             bonus) requires the multisig.
///           - Pausing the live minter requires the multisig.
///           - The deploying EOA is no longer privileged on either
///             contract — the chat-leaked testnet key is no longer a
///             standing risk.
///
/// @dev Reads from environment:
///   WNDY      (address) — Windy token to migrate roles on
///   MINTER    (address) — current ZkExecutionMinterV2 to migrate
///   MULTISIG  (address) — Safe (or other) multisig that takes over
contract MigrateAdmin is Script {
    function run() external {
        address wndyAddr = vm.envAddress("WNDY");
        address minterAddr = vm.envAddress("MINTER");
        address multisig = vm.envAddress("MULTISIG");

        Windy wndy = Windy(wndyAddr);
        ZkExecutionMinterV2 minter = ZkExecutionMinterV2(minterAddr);

        bytes32 adminRole = 0x00; // DEFAULT_ADMIN_ROLE
        bytes32 pauserRole = minter.PAUSER_ROLE();

        address eoa = msg.sender;

        vm.startBroadcast();

        // 1. Token: grant admin to multisig, then EOA renounces.
        wndy.grantRole(adminRole, multisig);
        wndy.renounceRole(adminRole, eoa);

        // 2. Minter: grant admin + pauser to multisig, then EOA renounces both.
        minter.grantRole(adminRole, multisig);
        minter.grantRole(pauserRole, multisig);
        minter.renounceRole(adminRole, eoa);
        minter.renounceRole(pauserRole, eoa);

        vm.stopBroadcast();

        console.log("Multisig now holds:");
        console.log("  Windy DEFAULT_ADMIN_ROLE   ->", multisig);
        console.log("  Minter DEFAULT_ADMIN_ROLE  ->", multisig);
        console.log("  Minter PAUSER_ROLE         ->", multisig);
        console.log("EOA", eoa, "no longer privileged on either contract.");
    }
}
