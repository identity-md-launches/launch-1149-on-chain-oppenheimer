// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IERC20
/// @notice The ERC-20 interface (EIP-20) together with the optional metadata functions.
interface IERC20 {
    /// @notice Emitted when `value` tokens move from `from` to `to`. Minting is `from == address(0)`.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when `owner` sets the allowance of `spender` to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Human-readable token name.
    function name() external view returns (string memory);

    /// @notice Token ticker.
    function symbol() external view returns (string memory);

    /// @notice Number of decimals the token's minor units are quoted in.
    function decimals() external view returns (uint8);

    /// @notice Total number of minor units in existence.
    function totalSupply() external view returns (uint256);

    /// @notice Minor units held by `account`.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Minor units `spender` may still move on behalf of `owner`.
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Moves `amount` from the caller to `to`. Returns true on success and reverts otherwise.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Sets the caller's allowance for `spender` to `amount`. Returns true on success.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance. Returns true on success.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
