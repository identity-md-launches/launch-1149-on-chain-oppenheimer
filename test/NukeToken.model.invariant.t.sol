// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {NukeToken} from "../src/NukeToken.sol";

/// @notice Model-based invariant suite. The handler keeps its own ledger of what every balance and
///         allowance must be after each call, predicts from that ledger whether the call must
///         succeed or revert (and with which error), performs the call, and asserts the outcome.
///         The invariants then compare the token against the ledger after every sequence.
/// @dev This is the "internal accounting = external reality" pattern plus per-operation
///      postconditions. Unlike the simpler suite in `NukeToken.invariant.t.sol`, it
///      - drives the zero address and the token contract itself as recipients,
///      - steers amounts onto the boundaries (0, exact balance, balance + 1),
///      - steers allowances onto the sentinels (0, max - 1, max),
///      - fails the run on any revert it did not predict (fail-on-revert is on), so a transfer that
///        a holder is entitled to make but cannot is caught, not skipped.
contract NukeTokenModelHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant INFINITE = type(uint256).max;

    NukeToken public immutable token;

    /// @dev Accounts that can sign: they send, approve and spend.
    address[] public actors;
    /// @dev Everything that may receive: the actors, the token contract (a sink) and the zero
    ///      address (must always be refused). Index == recipients.length - 1 is the zero address.
    address[] public recipients;

    /// @dev The ledger. Keyed by every address the handler ever touches.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    /// @dev Flow accounting, for invariants that do not depend on the ledger being right.
    uint256 public ghostMovedByTransfer;
    uint256 public ghostMovedByTransferFrom;
    uint256 public ghostSentToTokenContract;
    mapping(address => uint256) public ghostOut; // total ever debited from an account
    mapping(address => uint256) public ghostIn; // total ever credited to an account
    mapping(address => uint256) public ghostPulledByOthers; // debited via transferFrom by someone else

    /// @dev Outcome counters so the run can be read.
    uint256 public okTransfers;
    uint256 public okTransferFroms;
    uint256 public okApproves;
    uint256 public revertsZeroAddress;
    uint256 public revertsInsufficientBalance;
    uint256 public revertsInsufficientAllowance;
    uint256 public infiniteSpends;

    constructor(NukeToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            recipients.push(actors_[i]);
        }
        recipients.push(address(token_));
        recipients.push(address(0));

        // The deployer (actors_[0]) holds the whole supply at construction.
        ghostBalance[actors_[0]] = SUPPLY;
        ghostIn[actors_[0]] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, uint8 edge) external {
        address from = actors[fromSeed % actors.length];
        address to = recipients[toSeed % recipients.length];
        uint256 amount = _pickAmount(ghostBalance[from], amountSeed, edge);

        bytes memory expected = _expectedTransferRevert(from, to, amount);
        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));

        if (expected.length == 0) {
            assertTrue(ok, "a transfer the ledger allows reverted");
            assertTrue(abi.decode(ret, (bool)), "transfer returned false");
            _recordMove(from, to, amount);
            ghostMovedByTransfer += amount;
            okTransfers++;
        } else {
            assertFalse(ok, "a transfer the ledger forbids succeeded");
            assertEq(ret, expected, "transfer reverted with the wrong error");
            _countRevert(expected);
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint8 edge) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = recipients[spenderSeed % recipients.length];
        uint256 amount = _pickAllowance(amountSeed, edge);

        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.approve, (spender, amount)));

        if (spender == address(0)) {
            assertFalse(ok, "approving the zero spender succeeded");
            assertEq(ret, abi.encodeWithSelector(NukeToken.ZeroAddress.selector));
            revertsZeroAddress++;
        } else {
            assertTrue(ok, "approve reverted");
            assertTrue(abi.decode(ret, (bool)), "approve returned false");
            ghostAllowance[owner][spender] = amount;
            okApproves++;
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed, uint8 edge)
        external
    {
        address spender = actors[spenderSeed % actors.length];
        address from = actors[fromSeed % actors.length];
        address to = recipients[toSeed % recipients.length];
        uint256 allowed = ghostAllowance[from][spender];
        // Steer the amount onto the tighter of the two limits so both boundaries get exercised.
        uint256 limit = allowed == INFINITE || allowed > ghostBalance[from] ? ghostBalance[from] : allowed;
        uint256 amount = _pickAmount(limit, amountSeed, edge);

        bytes memory expected = _expectedTransferFromRevert(spender, from, to, amount);
        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));

        if (expected.length == 0) {
            assertTrue(ok, "a transferFrom the ledger allows reverted");
            assertTrue(abi.decode(ret, (bool)), "transferFrom returned false");
            if (allowed == INFINITE) {
                infiniteSpends++;
            } else {
                ghostAllowance[from][spender] = allowed - amount;
            }
            _recordMove(from, to, amount);
            if (spender != from) ghostPulledByOthers[from] += amount;
            ghostMovedByTransferFrom += amount;
            okTransferFroms++;
        } else {
            assertFalse(ok, "a transferFrom the ledger forbids succeeded");
            assertEq(ret, expected, "transferFrom reverted with the wrong error");
            _countRevert(expected);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 MODEL
    //////////////////////////////////////////////////////////////*/

    /// @dev Mirrors `_transfer`'s check order: zero recipient first, then balance.
    function _expectedTransferRevert(address from, address to, uint256 amount) internal view returns (bytes memory) {
        if (to == address(0)) return abi.encodeWithSelector(NukeToken.ZeroAddress.selector);
        uint256 bal = ghostBalance[from];
        if (bal < amount) return abi.encodeWithSelector(NukeToken.InsufficientBalance.selector, from, bal, amount);
        return "";
    }

    /// @dev Mirrors `transferFrom`: allowance is spent before `_transfer` runs its checks.
    function _expectedTransferFromRevert(address spender, address from, address to, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed != INFINITE && allowed < amount) {
            return abi.encodeWithSelector(NukeToken.InsufficientAllowance.selector, spender, allowed, amount);
        }
        return _expectedTransferRevert(from, to, amount);
    }

    function _recordMove(address from, address to, uint256 amount) internal {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostOut[from] += amount;
        ghostIn[to] += amount;
        if (to == address(token)) ghostSentToTokenContract += amount;
    }

    function _countRevert(bytes memory expected) internal {
        bytes4 sel = bytes4(expected);
        if (sel == NukeToken.ZeroAddress.selector) revertsZeroAddress++;
        else if (sel == NukeToken.InsufficientBalance.selector) revertsInsufficientBalance++;
        else if (sel == NukeToken.InsufficientAllowance.selector) revertsInsufficientAllowance++;
    }

    /// @dev One in four calls lands exactly on a boundary of `limit`; the rest are bounded within it
    ///      or slightly above it.
    function _pickAmount(uint256 limit, uint256 seed, uint8 edge) internal pure returns (uint256) {
        uint8 mode = edge % 8;
        if (mode == 0) return limit; // exactly everything allowed
        if (mode == 1) return limit + 1; // one too many
        if (mode == 2) return 0; // nothing
        if (mode == 3) return limit == 0 ? 0 : 1; // one wei
        if (mode == 4) return _bound(seed, limit, limit + limit / 2 + 2); // at or above
        return _bound(seed, 0, limit); // ordinary, within the limit
    }

    function _pickAllowance(uint256 seed, uint8 edge) internal pure returns (uint256) {
        uint8 mode = edge % 8;
        if (mode == 0) return INFINITE;
        if (mode == 1) return INFINITE - 1;
        if (mode == 2) return 0;
        if (mode == 3) return SUPPLY;
        if (mode == 4) return SUPPLY + 1;
        return _bound(seed, 0, SUPPLY);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract NukeTokenModelInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    NukeToken internal token;
    NukeTokenModelHandler internal handler;
    address[] internal actors;

    function setUp() public {
        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new NukeToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("distributor"));
        actors.push(makeAddr("poolManager"));
        actors.push(address(new ContractHolder())); // a holder that is a contract

        handler = new NukeTokenModelHandler(token, actors);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL ACCOUNTING = EXTERNAL REALITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Every balance the token reports is what the ledger says it must be.
    function invariant_balancesMatchTheLedger() public view {
        uint256 n = handler.recipientCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.recipients(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance drifted from the ledger");
        }
    }

    /// @dev Every allowance the token reports is what the ledger says it must be, including the
    ///      infinite sentinel surviving any number of spends and max - 1 being decremented.
    function invariant_allowancesMatchTheLedger() public view {
        uint256 n = handler.actorCount();
        uint256 m = handler.recipientCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < m; ++j) {
                address spender = handler.recipients(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               CONSERVATION
    //////////////////////////////////////////////////////////////*/

    /// @dev The supply reported never changes and equals the sum of every balance the handler can
    ///      have credited, including what was sunk into the token contract.
    function invariant_supplyIsConservedAcrossEveryHolder() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        uint256 sum;
        uint256 n = handler.recipientCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.recipients(i));
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
    }

    /// @dev Flow accounting closes: for every account, balance = in - out, with the deployer's
    ///      mint counted as its first inflow.
    function invariant_everyBalanceIsInflowMinusOutflow() public view {
        uint256 n = handler.recipientCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.recipients(i);
            assertEq(token.balanceOf(a), handler.ghostIn(a) - handler.ghostOut(a), "flows do not close");
        }
    }

    /// @dev Everything that ever moved, moved through transfer or transferFrom: no other path exists.
    function invariant_allMovementWentThroughTheTwoTransferPaths() public view {
        uint256 totalOut;
        uint256 n = handler.recipientCount();
        for (uint256 i; i < n; ++i) {
            totalOut += handler.ghostOut(handler.recipients(i));
        }
        assertEq(totalOut, handler.ghostMovedByTransfer() + handler.ghostMovedByTransferFrom());
    }

    /*//////////////////////////////////////////////////////////////
                              NEGATIVE STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev The zero address never holds anything, however many times it was targeted.
    function invariant_zeroAddressNeverReceives() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(handler.ghostBalance(address(0)), 0);
    }

    /// @dev Tokens sent to the token contract stay there: no path drains them back out.
    function invariant_tokenContractIsASink() public view {
        assertEq(token.balanceOf(address(token)), handler.ghostSentToTokenContract());
        assertEq(handler.ghostOut(address(token)), 0);
    }

    /// @dev Nobody ever holds more than the supply, and nobody's allowance read is ever corrupted
    ///      into a value the ledger never set (checked pairwise above; here the global bound).
    function invariant_noBalanceExceedsSupply() public view {
        uint256 n = handler.recipientCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.recipients(i)), SUPPLY);
        }
    }

    /// @dev What was pulled from an owner by other spenders never exceeds what that owner was
    ///      credited in total: a spender cannot create tokens by spending allowance.
    function invariant_pullsNeverExceedWhatTheOwnerEverHeld() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertLe(handler.ghostPulledByOthers(a), handler.ghostIn(a));
        }
    }

    /// @dev Reads back the run so a silent harness (all calls discarded) is visible in the log.
    function invariant_callSummary() public {
        // Not an assertion on behaviour: every path is counted so a run where, say, no
        // InsufficientAllowance revert was ever produced can be seen in `-vv` output.
        emit log_named_uint("ok transfers", handler.okTransfers());
        emit log_named_uint("ok transferFroms", handler.okTransferFroms());
        emit log_named_uint("ok approves", handler.okApproves());
        emit log_named_uint("infinite-allowance spends", handler.infiniteSpends());
        emit log_named_uint("reverts ZeroAddress", handler.revertsZeroAddress());
        emit log_named_uint("reverts InsufficientBalance", handler.revertsInsufficientBalance());
        emit log_named_uint("reverts InsufficientAllowance", handler.revertsInsufficientAllowance());
    }
}

/// @dev A holder with code, so the handler also moves tokens to and from a contract account.
contract ContractHolder {}
