// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {NukeToken} from "../src/NukeToken.sol";

/// @notice Edge cases the unit suite in `NukeToken.t.sol` does not pin: the inputs the author did
///         not have in mind (self as counterparty, the token contract as recipient, zero amounts
///         with zero allowance, the sentinel's neighbour, revert ordering, ETH attached to calls),
///         the exact ERC-20 ABI, and arithmetic properties fuzzed at their edges.
/// forge-config: default.fuzz.runs = 1000
contract NukeTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant INFINITE = type(uint256).max;

    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

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
                        COUNTERPARTIES THE AUTHOR FORGOT
    //////////////////////////////////////////////////////////////*/

    /// @dev Sending to the token contract is allowed by ERC-20 and, with no rescue path, final.
    function test_transfer_toTokenContractSucceedsAndIsIrrecoverable() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);

        // Nobody, including the deployer, can pull it back: the contract never approves anyone.
        assertEq(token.allowance(address(token), deployer), 0);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, deployer, 0, 1 ether));
        vm.prank(deployer);
        token.transferFrom(address(token), deployer, 1 ether);
    }

    function test_transfer_toSelfAboveBalanceStillReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 3);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, alice, 3, 4));
        vm.prank(alice);
        token.transfer(alice, 4);
        assertEq(token.balanceOf(alice), 3);
    }

    function test_transfer_toSelfOfExactBalanceIsANoOp() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev `from == to` in transferFrom: the balance is unchanged but the allowance is still spent.
    function test_transferFrom_fromEqualsTo_keepsBalanceSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 4 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, spender), 6 ether);
    }

    /// @dev The spender sending to itself is an ordinary pull.
    function test_transferFrom_toSpender() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, spender, 10 ether));
        assertEq(token.balanceOf(spender), 10 ether);
        assertEq(token.allowance(deployer, spender), 0);
    }

    /// @dev Zero-value transferFrom needs no allowance (0 >= 0) and no balance: it still emits.
    function test_transferFrom_zeroAmountWithoutAllowanceOrBalanceSucceeds() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
    }

    /// @dev ...but a zero-value move to the zero address is still refused.
    function test_transferFrom_zeroAmountToZeroAddressReverts() public {
        vm.expectRevert(NukeToken.ZeroAddress.selector);
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 0);
    }

    function test_transfer_zeroAmountToZeroAddressReverts() public {
        vm.expectRevert(NukeToken.ZeroAddress.selector);
        vm.prank(alice);
        token.transfer(address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              REVERT ORDERING
    //////////////////////////////////////////////////////////////*/

    /// @dev Allowance is checked before the recipient and the balance: a spender with no allowance
    ///      learns nothing about the owner's balance from the error.
    function test_transferFrom_checksAllowanceBeforeRecipientAndBalance() public {
        // No allowance, zero recipient, no balance: the allowance error wins.
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, address(0), 1);

        // Infinite allowance, zero recipient, no balance: the recipient error wins over balance.
        vm.prank(alice);
        token.approve(spender, INFINITE);
        vm.expectRevert(NukeToken.ZeroAddress.selector);
        vm.prank(spender);
        token.transferFrom(alice, address(0), 1);

        // Infinite allowance, good recipient, no balance: finally the balance error.
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    /*//////////////////////////////////////////////////////////////
                         THE SENTINEL AND ITS NEIGHBOUR
    //////////////////////////////////////////////////////////////*/

    function test_transferFrom_maxMinusOneAllowanceIsFiniteAndDecremented() public {
        vm.prank(deployer);
        token.approve(spender, INFINITE - 1);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), INFINITE - 2);
    }

    function test_transferFrom_infiniteAllowanceStillRequiresBalance() public {
        vm.prank(alice);
        token.approve(spender, INFINITE);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), INFINITE, "a failed pull must not touch the sentinel");
    }

    function test_transferFrom_infiniteAllowanceSurvivesSpendingTheWholeSupply() public {
        vm.prank(deployer);
        token.approve(spender, INFINITE);
        vm.prank(spender);
        token.transferFrom(deployer, bob, SUPPLY);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.allowance(deployer, spender), INFINITE);
    }

    /// @dev An infinite allowance can be revoked: it is not sticky.
    function test_approve_canRevokeInfiniteAllowance() public {
        vm.startPrank(deployer);
        token.approve(spender, INFINITE);
        token.approve(spender, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                 APPROVALS
    //////////////////////////////////////////////////////////////*/

    function test_approve_selfAllowanceIsOrdinary() public {
        vm.prank(deployer);
        token.approve(deployer, 5);
        assertEq(token.allowance(deployer, deployer), 5);
    }

    function test_approve_sameValueTwiceEmitsTwice() public {
        vm.recordLogs();
        vm.startPrank(deployer);
        token.approve(spender, 1 ether);
        token.approve(spender, 1 ether);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], APPROVAL_TOPIC);
        assertEq(logs[1].topics[0], APPROVAL_TOPIC);
    }

    function test_approve_isPerSpenderAndPerOwner() public {
        vm.prank(deployer);
        token.approve(spender, 7);
        assertEq(token.allowance(deployer, alice), 0, "a different spender gained an allowance");
        assertEq(token.allowance(alice, spender), 0, "a different owner gave an allowance");
        assertEq(token.allowance(spender, deployer), 0, "the allowance is directional");
    }

    function test_allowance_unsetPairsReadZero_includingZeroAddresses() public view {
        assertEq(token.allowance(address(0), address(0)), 0);
        assertEq(token.allowance(deployer, address(0)), 0);
        assertEq(token.allowance(address(0), deployer), 0);
        assertEq(token.allowance(address(token), deployer), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev transferFrom emits exactly one Transfer and no Approval: the allowance change is
    ///      observable only through `allowance()`.
    function test_transferFrom_emitsExactlyOneTransferAndNoApproval() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(deployer, bob, 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emitted more than one event");
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), deployer);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 3);
    }

    function test_transfer_emitsExactlyOneEvent() public {
        vm.recordLogs();
        vm.prank(deployer);
        token.transfer(alice, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
    }

    function test_deploymentEmitsExactlyOneMintEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        NukeToken fresh = new NukeToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the constructor emitted more than the mint");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(uint256(logs[0].topics[1]), 0, "mint must come from the zero address");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), alice);
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_failedCallsEmitNothing() public {
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (bob, 1)));
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(token).call(abi.encodeCall(IERC20.approve, (address(0), 1)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                             THE EXACT ERC-20 ABI
    //////////////////////////////////////////////////////////////*/

    /// @dev The launch floor, the distributor and the pool manager speak the standard ABI by
    ///      signature. Every standard selector must answer and decode as the standard says.
    function test_standardSelectorsAnswerAndDecode() public {
        (bool ok, bytes memory ret) = address(token).staticcall(abi.encodeWithSignature("name()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (string)), "On-Chain Oppenheimer");

        (ok, ret) = address(token).staticcall(abi.encodeWithSignature("symbol()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (string)), "NUKE");

        (ok, ret) = address(token).staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint8)), 18);

        (ok, ret) = address(token).staticcall(abi.encodeWithSignature("totalSupply()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), SUPPLY);

        (ok, ret) = address(token).staticcall(abi.encodeWithSignature("balanceOf(address)", deployer));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), SUPPLY);

        (ok, ret) = address(token).staticcall(abi.encodeWithSignature("allowance(address,address)", deployer, spender));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 0);

        vm.prank(deployer);
        (ok, ret) = address(token).call(abi.encodeWithSignature("approve(address,uint256)", spender, 5));
        assertTrue(ok);
        assertEq(ret.length, 32, "approve must return a bool word");
        assertTrue(abi.decode(ret, (bool)));

        vm.prank(deployer);
        (ok, ret) = address(token).call(abi.encodeWithSignature("transfer(address,uint256)", alice, 2));
        assertTrue(ok);
        assertEq(ret.length, 32, "transfer must return a bool word");
        assertTrue(abi.decode(ret, (bool)));

        vm.prank(spender);
        (ok, ret) =
            address(token).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", deployer, bob, 5));
        assertTrue(ok);
        assertEq(ret.length, 32, "transferFrom must return a bool word");
        assertTrue(abi.decode(ret, (bool)));
        assertEq(token.balanceOf(bob), 5);
    }

    function test_eventSignaturesAreTheStandardOnes() public pure {
        assertEq(IERC20.Transfer.selector, TRANSFER_TOPIC);
        assertEq(IERC20.Approval.selector, APPROVAL_TOPIC);
        assertEq(TRANSFER_TOPIC, 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef);
        assertEq(APPROVAL_TOPIC, 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925);
    }

    /// @dev None of the mutators are payable: value attached to a valid call reverts the call.
    function test_mutatorsRefuseAttachedValue() public {
        vm.deal(deployer, 3);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.transfer, (alice, 1)));
        assertFalse(ok, "transfer accepted ETH");
        vm.prank(deployer);
        (ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.approve, (spender, 1)));
        assertFalse(ok, "approve accepted ETH");
        vm.prank(deployer);
        token.approve(spender, 1);
        vm.deal(spender, 1);
        vm.prank(spender);
        (ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.transferFrom, (deployer, bob, 1)));
        assertFalse(ok, "transferFrom accepted ETH");
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev The views are pure/view: a staticcall must not fail on them.
    function test_viewsAreStatic() public view {
        (bool ok,) = address(token).staticcall(abi.encodeCall(IERC20.balanceOf, (deployer)));
        assertTrue(ok);
        (ok,) = address(token).staticcall(abi.encodeCall(IERC20.allowance, (deployer, spender)));
        assertTrue(ok);
        (ok,) = address(token).staticcall(abi.encodeCall(IERC20.totalSupply, ()));
        assertTrue(ok);
    }

    /*//////////////////////////////////////////////////////////////
                            INDEPENDENT DEPLOYMENTS
    //////////////////////////////////////////////////////////////*/

    function test_twoDeploymentsDoNotShareState() public {
        vm.prank(alice);
        NukeToken other = new NukeToken();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(alice), 0);

        vm.prank(deployer);
        token.approve(spender, 9);
        assertEq(other.allowance(deployer, spender), 0);

        vm.prank(deployer);
        token.transfer(bob, 1);
        assertEq(other.balanceOf(bob), 0);
        assertEq(other.balanceOf(deployer), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           ARITHMETIC AT THE EDGES
    //////////////////////////////////////////////////////////////*/

    /// @dev A transfer of `a` then `b` leaves exactly the same state as one transfer of `a + b`.
    function testFuzz_transfersAreAdditive(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.transfer(alice, b);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), a + b);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }

    /// @dev Sending and sending back restores both balances exactly: there is no fee either way.
    function testFuzz_roundTripRestoresBothBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev The balance boundary: exactly the balance goes through, one more wei does not.
    function testFuzz_transferBoundaryIsExact(uint256 held) public {
        held = bound(held, 0, SUPPLY - 1);
        vm.prank(deployer);
        token.transfer(alice, held);

        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, alice, held, held + 1));
        vm.prank(alice);
        token.transfer(bob, held + 1);
        assertEq(token.balanceOf(alice), held, "a failed transfer changed the balance");

        vm.prank(alice);
        assertTrue(token.transfer(bob, held));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), held);
    }

    /// @dev The allowance boundary: exactly the allowance goes through, one more wei does not,
    ///      for every finite allowance up to the supply.
    function testFuzz_allowanceBoundaryIsExact(uint256 allowed) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        vm.prank(deployer);
        token.approve(spender, allowed);

        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, spender, allowed, allowed + 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, allowed + 1);
        assertEq(token.allowance(deployer, spender), allowed, "a failed pull changed the allowance");

        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, allowed));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(bob), allowed);
    }

    /// @dev Any finite allowance, even far above the supply, is decremented by exactly the amount
    ///      moved; only the exact sentinel is left alone.
    function testFuzz_onlyTheExactSentinelIsInfinite(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, SUPPLY, INFINITE);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        token.transferFrom(deployer, bob, amount);
        if (allowed == INFINITE) {
            assertEq(token.allowance(deployer, spender), INFINITE);
        } else {
            assertEq(token.allowance(deployer, spender), allowed - amount);
        }
        assertEq(token.balanceOf(bob), amount);
    }

    /// @dev A pull moves exactly `amount` between exactly two parties; the spender's own balance
    ///      and every bystander's are untouched.
    function testFuzz_transferFromTouchesOnlyFromAndTo(uint256 amount, uint256 spenderHeld) public {
        amount = bound(amount, 0, SUPPLY / 2);
        spenderHeld = bound(spenderHeld, 0, SUPPLY / 2);
        vm.startPrank(deployer);
        token.transfer(spender, spenderHeld);
        token.approve(spender, amount);
        vm.stopPrank();
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.prank(spender);
        token.transferFrom(deployer, bob, amount);

        assertEq(token.balanceOf(deployer), deployerBefore - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(spender), spenderHeld, "the spender's own balance moved");
        assertEq(token.balanceOf(alice), 0, "a bystander's balance moved");
        assertEq(token.balanceOf(deployer) + token.balanceOf(bob) + token.balanceOf(spender), SUPPLY);
    }

    /// @dev Every approval value reads back exactly, including 0, the sentinel and its neighbour.
    function testFuzz_approveReadsBackExactly(uint256 amount) public {
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(alice, spender), amount);
    }

    /// @dev Revert data carries the real numbers, for any holder and any overdraft.
    function testFuzz_insufficientBalanceReportsRealNumbers(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, INFINITE - held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, alice, held, held + excess));
        vm.prank(alice);
        token.transfer(bob, held + excess);
    }

    /// @dev Any caller can be a spender, any address a recipient: there is no allow-list anywhere.
    function testFuzz_anyoneCanSpendWhatTheyAreAllowed(address who, address to, uint256 amount) public {
        who = address(uint160(bound(uint256(uint160(who)), 1, type(uint160).max)));
        to = address(uint160(bound(uint256(uint160(to)), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(who, amount);
        uint256 toBefore = token.balanceOf(to);
        uint256 deployerBefore = token.balanceOf(deployer);
        vm.prank(who);
        assertTrue(token.transferFrom(deployer, to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), deployerBefore);
        } else {
            assertEq(token.balanceOf(to), toBefore + amount);
            assertEq(token.balanceOf(deployer), deployerBefore - amount);
        }
        assertEq(token.allowance(deployer, who), 0);
    }
}
