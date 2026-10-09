// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployNukeToken} from "../script/DeployNukeToken.s.sol";
import {NukeToken} from "../src/NukeToken.sol";

/// @notice Exercises the deploy script's logic directly, with no environment and no broadcast.
contract DeployNukeTokenTest is Test {
    function test_deployMintsWholeSupplyToTheScriptCaller() public {
        DeployNukeToken script = new DeployNukeToken();
        NukeToken token = script.deploy();

        // `deploy()` creates the token from the script contract, so the script holds the supply
        // here; under `forge script --broadcast` the broadcasting signer is the creator instead.
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(script)), 1_000_000_000 ether);
        assertEq(token.name(), "On-Chain Oppenheimer");
        assertEq(token.symbol(), "NUKE");
        assertEq(token.decimals(), 18);
    }

    function test_deployIsRepeatableAndIndependent() public {
        DeployNukeToken script = new DeployNukeToken();
        NukeToken a = script.deploy();
        NukeToken b = script.deploy();
        assertTrue(address(a) != address(b));
        assertEq(a.balanceOf(address(script)), 1_000_000_000 ether);
        assertEq(b.balanceOf(address(script)), 1_000_000_000 ether);
    }
}
