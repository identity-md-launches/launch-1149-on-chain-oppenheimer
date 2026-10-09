// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {NukeToken} from "../src/NukeToken.sol";

/// @title DeployNukeToken
/// @notice Reviewable deployment of `NukeToken` for a standalone deployment or a local fork.
/// @dev The IdentityMD launch does NOT use this script: the ProjectFactory deploys the token from
///      its built bytecode, so the factory becomes `msg.sender` and receives the whole supply. This
///      script exists so the deployment can be reproduced and reviewed elsewhere. It takes no
///      configuration: the token has no constructor arguments. `run()` broadcasts with whatever
///      signer `forge script` is given; `deploy()` is the pure logic the tests call directly.
contract DeployNukeToken is Script {
    /// @notice Deploys the token. The caller of this function's broadcast context receives the supply.
    function deploy() public returns (NukeToken token) {
        token = new NukeToken();
    }

    /// @notice Entry point for `forge script`. Broadcasts a single deployment transaction.
    function run() external returns (NukeToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
