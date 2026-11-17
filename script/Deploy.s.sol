// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {UnstakingShMonVault} from "../src/UnstakingShMonVault.sol";

/// @notice Deploys one ushMON vault. Env: EVC, SHMON, WMON, OPERATORS (comma-separated exit desks allowed to mint shares and
///         start unstakes; v3 serves several).
///         forge script script/Deploy.s.sol --rpc-url $MONAD_RPC_URL --broadcast --private-key $PK
contract Deploy is Script {
    function run() external returns (UnstakingShMonVault vault) {
        vm.startBroadcast();
        vault = new UnstakingShMonVault(
            vm.envAddress("EVC"), vm.envAddress("SHMON"), vm.envAddress("SHMON"), vm.envAddress("WMON"), vm.envAddress("OPERATORS", ",")
        );
        vm.stopBroadcast();
    }
}
