// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title On-Chain Oppenheimer (NUKE)
/// @notice A fixed-supply ERC-20. The whole supply, 1,000,000,000 NUKE with 18 decimals, is
///         minted once to the deployer in the constructor. Nothing can mint afterwards.
/// @dev Deliberately minimal:
///      - no owner, no admin role, no pause, no blacklist, no fee or burn on transfer;
///      - no external calls anywhere, so the constructor runs on an empty chain;
///      - no `delegatecall`, `callcode` or `selfdestruct`;
///      - balances only move through `transfer` and `transferFrom` authorised by the holder.
///      The contract name is `NukeToken`; `name()` and `symbol()` carry the token's branding.
contract NukeToken is IERC20 {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice A transfer or approval named the zero address where a real account is required.
    error ZeroAddress();

    /// @notice `from` holds less than `needed`.
    error InsufficientBalance(address from, uint256 balance, uint256 needed);

    /// @notice `spender` is allowed less than `needed` by the owner.
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Human-readable name returned by `name()`.
    string public constant NAME = "On-Chain Oppenheimer";

    /// @notice Ticker returned by `symbol()`.
    string public constant SYMBOL = "NUKE";

    /// @notice Decimal places returned by `decimals()`.
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply in minor units: 1,000,000,000 * 10**18. Minted once, never again.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address account => uint256) private _balances;

    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints the entire fixed supply to the deployer (`msg.sender`).
    /// @dev Takes no arguments and makes no external calls. At launch `msg.sender` is the
    ///      ProjectFactory, which then distributes the supply; for any other deployment it is
    ///      whoever deploys the contract.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20
    function name() external pure override returns (string memory) {
        return NAME;
    }

    /// @inheritdoc IERC20
    function symbol() external pure override returns (string memory) {
        return SYMBOL;
    }

    /// @inheritdoc IERC20
    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20
    /// @dev Constant: the supply can neither grow nor shrink after the constructor.
    function totalSupply() external pure override returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    /*//////////////////////////////////////////////////////////////
                                MUTATORS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20
    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc IERC20
    /// @dev Setting `amount` to `type(uint256).max` grants an allowance that `transferFrom`
    ///      does not decrement. Approvals are overwritten, not added: callers racing an
    ///      approval change should set the allowance to zero first.
    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // fromBalance >= amount was just checked, and no balance can exceed the fixed
            // total supply, so the credit cannot overflow.
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, current, amount);
        unchecked {
            _allowances[owner][spender] = current - amount;
        }
    }
}
