// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CampusToken} from "../src/CampusToken.sol";

/// @notice Deploys CampusToken.
///
///     PRIVATE_KEY=0x... ADMIN_ADDRESS=0x... TREASURY_ADDRESS=0x... \
///     forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
///
/// The admin is a separate setting from the deploying key on purpose: the key
/// that pays for the deployment can be a throwaway key while every role goes
/// straight to a multisig. If ADMIN_ADDRESS is not set, the deployer becomes the
/// admin and the script says so.
contract Deploy is Script {
    function run() external returns (CampusToken token) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        uint256 cap = vm.envOr("TOKEN_CAP", uint256(1_000_000 ether));

        vm.startBroadcast(deployerKey);
        token = new CampusToken("Campus Token", "CMPS", cap, admin, treasury);
        vm.stopBroadcast();

        console2.log("CampusToken:", address(token));
        console2.log("admin      :", admin);
        console2.log("treasury   :", treasury);
        console2.log("cap        :", cap);
        if (admin == deployer) {
            console2.log("note: the deploying key is the admin; hand the roles to a multisig");
        }
    }
}
