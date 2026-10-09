// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {NukeToken} from "../src/NukeToken.sol";

/// @notice Unit tests for the fixed-supply NUKE token: metadata, the one-time mint, every success
///         and failure path of transfer/approve/transferFrom, and the absence of admin powers.
contract NukeTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    NukeToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new NukeToken();
    }

    /*//////////////////////////////////////////////////////////////
                           METADATA AND SUPPLY
    //////////////////////////////////////////////////////////////*/

    function test_metadata() public view {
        assertEq(token.name(), "On-Chain Oppenheimer");
        assertEq(token.symbol(), "NUKE");
        assertEq(token.decimals(), 18);
        assertEq(token.NAME(), "On-Chain Oppenheimer");
        assertEq(token.SYMBOL(), "NUKE");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        address other = makeAddr("other");
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), other, SUPPLY);
        vm.prank(other);
        NukeToken fresh = new NukeToken();
        assertEq(fresh.balanceOf(other), SUPPLY);
    }

    function test_constructorMintsToWhoeverDeploys_evenAContract() public {
        Deployer d = new Deployer();
        NukeToken fresh = d.deploy();
        assertEq(fresh.balanceOf(address(d)), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_constructorHasNoArgumentsAndMakesNoExternalCalls() public {
        // Deploy on an otherwise empty address space from an EOA with no code anywhere else:
        // if the constructor called another contract the deployment would revert.
        address lonely = address(0x1234567890123456789012345678901234567890);
        vm.prank(lonely);
        NukeToken fresh = new NukeToken();
        assertEq(fresh.balanceOf(lonely), SUPPLY);
    }

    /*//////////////////////////////////////////////////////////////
                                TRANSFER
    //////////////////////////////////////////////////////////////*/

    function test_transfer_movesExactAmountAndEmits() public {
        uint256 amount = 1_234_567 ether;
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));

        assertEq(token.balanceOf(alice), amount, "recipient got less than sent");
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY, "transfer changed the supply");
    }

    function test_transfer_fullBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transfer_zeroAmountSucceeds() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transfer_toSelfIsANoOp() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 100 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, alice, 10 ether, 10 ether + 1));
        vm.prank(alice);
        token.transfer(bob, 10 ether + 1);

        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transfer_revertsWhenSenderHoldsNothing() public {
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transfer(alice, 1);
    }

    function test_transfer_revertsToZeroAddress() public {
        vm.expectRevert(NukeToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.transfer(address(0), 1 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /*//////////////////////////////////////////////////////////////
                                APPROVE
    //////////////////////////////////////////////////////////////*/

    function test_approve_setsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, spender, 5 ether);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 5 ether));
        assertEq(token.allowance(deployer, spender), 5 ether);
    }

    function test_approve_overwritesRatherThanAdds() public {
        vm.startPrank(deployer);
        token.approve(spender, 5 ether);
        token.approve(spender, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 2 ether);
    }

    function test_approve_canExceedBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, SUPPLY * 2));
        assertEq(token.allowance(alice, spender), SUPPLY * 2);
    }

    function test_approve_revertsForZeroSpender() public {
        vm.expectRevert(NukeToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    /*//////////////////////////////////////////////////////////////
                              TRANSFER FROM
    //////////////////////////////////////////////////////////////*/

    function test_transferFrom_spendsAllowanceAndMovesTokens() public {
        vm.prank(deployer);
        token.approve(spender, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, bob, 60 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));

        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 60 ether);
        assertEq(token.allowance(deployer, spender), 40 ether);
        assertEq(token.balanceOf(spender), 0, "the spender must not receive anything");
    }

    function test_transferFrom_exactAllowanceLeavesZero() public {
        vm.prank(deployer);
        token.approve(spender, 7 ether);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 7 ether);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_transferFrom_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 123 ether);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), 123 ether);
    }

    function test_transferFrom_ownerCanSpendOwnTokensOnlyWithSelfAllowance() public {
        // transferFrom by the owner is still gated by the allowance the owner gave itself.
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, bob, 1);

        vm.startPrank(deployer);
        token.approve(deployer, 1);
        assertTrue(token.transferFrom(deployer, bob, 1));
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 1);
    }

    function test_transferFrom_revertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, spender, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFrom_revertsWhenAllowanceTooSmall() public {
        vm.prank(deployer);
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, spender, 1 ether, 1 ether + 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1 ether + 1);
        assertEq(token.allowance(deployer, spender), 1 ether, "a failed transferFrom must not spend allowance");
    }

    function test_transferFrom_revertsWhenOwnerBalanceTooSmall() public {
        vm.prank(alice);
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, alice, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, spender), 1 ether, "a failed transferFrom must not spend allowance");
    }

    function test_transferFrom_revertsToZeroAddress() public {
        vm.prank(deployer);
        token.approve(spender, 1 ether);
        vm.expectRevert(NukeToken.ZeroAddress.selector);
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                           NO PRIVILEGED POWERS
    //////////////////////////////////////////////////////////////*/

    function test_noMintOrAdminSelectorExists() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setMinter(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_deployerCannotMoveAnotherHoldersBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);

        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);

        assertEq(token.balanceOf(alice), 5 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 2 ether));
        assertEq(token.balanceOf(bob), 2 ether);
    }

    function test_unknownCallsRevert() public {
        (bool ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "unknown selectors must revert");
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "plain ETH must be refused");
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_transfer_conservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer) + token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transfer_revertsAboveBalance(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, deployer, SUPPLY, amount));
        vm.prank(deployer);
        token.transfer(alice, amount);
    }

    function testFuzz_transferFrom_decrementsAllowanceExactly(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1); // keep the infinite sentinel out
        amount = bound(amount, 0, allowed < SUPPLY ? allowed : SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.allowance(deployer, spender), allowed - amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_transferFrom_revertsAboveAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, spender, allowed, amount));
        vm.prank(spender);
        token.transferFrom(deployer, bob, amount);
    }

    function testFuzz_chainOfTransfersConservesSupply(uint8 hops, uint256 seed) public {
        address current = deployer;
        uint256 total;
        for (uint256 i; i < hops; ++i) {
            address next = address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1));
            uint256 amount = token.balanceOf(current) / 2;
            vm.prank(current);
            token.transfer(next, amount);
            total += token.balanceOf(current);
            current = next;
        }
        total += token.balanceOf(current);
        assertEq(total, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}

/// @dev A contract that deploys the token, standing in for the launch factory.
contract Deployer {
    function deploy() external returns (NukeToken) {
        return new NukeToken();
    }
}
