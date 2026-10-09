// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NukeToken} from "../src/NukeToken.sol";

/// @notice Drives random transfers, approvals and transferFroms between a fixed set of actors and
///         checks that the supply is conserved and matches the sum of balances.
contract NukeTokenHandler is Test {
    NukeToken public immutable token;
    address[] public actors;

    uint256 public ghostTransfers;
    uint256 public ghostReverts;

    constructor(NukeToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from) * 2 + 1);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeWithSelector(token.transfer.selector, to, amount));
        if (ok) ghostTransfers++;
        else ghostReverts++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = actors[spenderSeed % actors.length];
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from) * 2 + 1);
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, amount));
        if (ok) ghostTransfers++;
        else ghostReverts++;
    }
}

contract NukeTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    NukeToken internal token;
    NukeTokenHandler internal handler;
    address[] internal actors;

    function setUp() public {
        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new NukeToken();

        actors.push(deployer);
        for (uint256 i = 1; i < 6; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        handler = new NukeTokenHandler(token, actors);

        targetContract(address(handler));
    }

    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
    }

    function invariant_noBalanceExceedsSupply() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(token.balanceOf(actors[i]), SUPPLY);
        }
    }
}
