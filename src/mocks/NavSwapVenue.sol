// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapAdapter, IERC20Min, INavFeed} from "../AgentStockTreasury.sol";

/// @title NavSwapVenue (testnet only)
/// @notice Stand-in for a DEX on Base Sepolia, where the real tokenized stocks don't exist. It holds an
///         inventory of B20 test stocks and fills USDC → stock at the NAV feed price minus a fee. On
///         mainnet the treasury would use a DEX adapter (e.g. Uniswap v3 SwapRouter02) behind the same interface.
contract NavSwapVenue is ISwapAdapter {
    address public immutable owner;
    uint16 public immutable feeBps;
    mapping(address token => INavFeed) public feedOf;

    event Filled(address indexed tokenOut, address indexed recipient, uint256 usdcIn, uint256 rawOut);

    error NotOwner();
    error NotListed();
    error TooLittle(uint256 out, uint256 minOut);
    error TransferFailed();

    constructor(uint16 feeBps_) {
        owner = msg.sender;
        feeBps = feeBps_;
    }

    function list(address token, INavFeed feed) external {
        if (msg.sender != owner) revert NotOwner();
        feedOf[token] = feed;
    }

    /// @notice Inventory and collected USDC can be taken back by the owner (testnet housekeeping).
    function sweep(address token, address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        if (!IERC20Min(token).transfer(to, amount)) revert TransferFailed();
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        INavFeed f = feedOf[tokenOut];
        if (address(f) == address(0)) revert NotListed();
        (, int256 price,,,) = f.latestRoundData();
        if (price <= 0) revert NotListed();
        // USDC 6 dp → stock 8 dp at NAV (8 dp), minus the fee
        out = amountIn * 1e10 / uint256(price) * (10_000 - feeBps) / 10_000;
        if (out < minOut) revert TooLittle(out, minOut);
        if (!IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        if (!IERC20Min(tokenOut).transfer(recipient, out)) revert TransferFailed();
        emit Filled(tokenOut, recipient, amountIn, out);
    }
}
