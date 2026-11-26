// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {IB20} from "base-std/interfaces/IB20.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

interface INavFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @notice A venue that swaps exact USDC in for a tokenized stock, honouring `minOut`.
interface ISwapAdapter {
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut);
}

/// @title AgentStockTreasury
/// @notice Lets an AI agent on BotHire keep part of what it earns in tokenized stocks.
///
///   1. The agent (its payout wallet) sets a rule: what share of each earning to invest, and a basket
///      of tokenized stocks with weights.
///   2. Whoever pays the agent for a job (BotHire's settlement, or the agent itself) calls
///      `depositEarning`. The USDC is split: the stock share waits in `pendingUsdc`, the rest stays
///      withdrawable as USDC.
///   3. Once the pending amount reaches `minBuyUsdc`, the treasury buys each basket leg through the
///      swap adapter, with a minimum output computed from the token's NAV feed and a slippage cap.
///      If a feed is stale or a token is paused, nothing is bought and the USDC stays pending.
///   4. Holdings are tracked per agent in raw token units. `holdingsOf` reports them as shares
///      (B20 `toUIAmount`, which follows splits and reinvested dividends) and as USD at NAV.
///
/// Tokenized stocks give economic exposure only; they carry no shareholder or voting rights.
/// Not available to US persons.
contract AgentStockTreasury {
    struct Leg {
        address token; // B20 tokenized stock
        uint16 weightBps; // share of each buy, sums to 10_000
    }

    struct Rule {
        uint16 shareBps; // part of each earning to invest, ≤ 10_000
        uint16 maxSlippageBps; // vs NAV, ≤ 1_000
        uint64 minBuyUsdc; // batch small earnings until at least this much is pending
        bool active;
    }

    struct Holding {
        address token;
        uint256 raw; // token units (8 decimals for Coinbase stocks)
        uint256 shares; // raw × uiMultiplier, the share-equivalent amount
        uint256 usdValue; // 6 decimals, at NAV
    }

    uint256 public constant MAX_LEGS = 5;
    uint256 public constant MAX_NAV_AGE = 4 days; // feeds pause over weekends and holidays

    IERC20Min public immutable usdc;
    address public immutable owner; // sets the venue and the stock list (operator of the service)
    ISwapAdapter public adapter;

    mapping(address token => address feed) public navFeedOf; // supported stocks and their NAV feeds
    mapping(address agent => Rule) public ruleOf;
    mapping(address agent => Leg[]) internal basketOf;
    mapping(address agent => uint256) public pendingUsdc; // waiting to be invested
    mapping(address agent => uint256) public cashUsdc; // not invested, withdrawable
    mapping(address agent => mapping(address token => uint256)) public rawHeld;

    event RuleSet(address indexed agent, uint16 shareBps, uint16 maxSlippageBps, uint64 minBuyUsdc, uint256 legs);
    event EarningDeposited(
        address indexed agent, address indexed payer, uint256 amount, uint256 toStocks, bytes32 jobRef
    );
    event Bought(address indexed agent, address indexed token, uint256 usdcIn, uint256 rawOut, uint256 sharesOut);
    event BuyDeferred(address indexed agent, address indexed token, string reason);
    event Withdrawn(address indexed agent, address indexed token, uint256 amount, address to);
    event StockListed(address indexed token, address feed);
    event AdapterSet(address adapter);

    error NotOwner();
    error BadRule();
    error NoRule();
    error TransferFailed();
    error Insufficient();

    constructor(IERC20Min usdc_, ISwapAdapter adapter_) {
        usdc = usdc_;
        owner = msg.sender;
        adapter = adapter_;
        emit AdapterSet(address(adapter_));
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------- operator

    function listStock(address token, address feed) external onlyOwner {
        navFeedOf[token] = feed;
        emit StockListed(token, feed);
    }

    function setAdapter(ISwapAdapter adapter_) external onlyOwner {
        adapter = adapter_;
        emit AdapterSet(address(adapter_));
    }

    // ---------------------------------------------------------------- agent

    /// @notice The agent sets its own investing rule. Weights must sum to 100% over listed stocks.
    function setRule(uint16 shareBps, uint16 maxSlippageBps, uint64 minBuyUsdc, Leg[] calldata legs) external {
        if (shareBps > 10_000 || maxSlippageBps > 1_000 || legs.length == 0 || legs.length > MAX_LEGS) {
            revert BadRule();
        }
        uint256 sum;
        for (uint256 i; i < legs.length; i++) {
            if (navFeedOf[legs[i].token] == address(0) || legs[i].weightBps == 0) revert BadRule();
            for (uint256 j; j < i; j++) {
                if (legs[j].token == legs[i].token) revert BadRule();
            }
            sum += legs[i].weightBps;
        }
        if (sum != 10_000) revert BadRule();
        ruleOf[msg.sender] = Rule(shareBps, maxSlippageBps, minBuyUsdc, true);
        delete basketOf[msg.sender];
        for (uint256 i; i < legs.length; i++) {
            basketOf[msg.sender].push(legs[i]);
        }
        emit RuleSet(msg.sender, shareBps, maxSlippageBps, minBuyUsdc, legs.length);
    }

    /// @notice Pays `amount` USDC to `agent` through its treasury (pulls from msg.sender).
    /// @param jobRef  the BotHire job this earning comes from, for the audit trail.
    function depositEarning(address agent, uint256 amount, bytes32 jobRef) external {
        Rule memory r = ruleOf[agent];
        if (!r.active) revert NoRule();
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        uint256 toStocks = amount * r.shareBps / 10_000;
        pendingUsdc[agent] += toStocks;
        cashUsdc[agent] += amount - toStocks;
        emit EarningDeposited(agent, msg.sender, amount, toStocks, jobRef);
        if (pendingUsdc[agent] >= r.minBuyUsdc) _invest(agent);
    }

    /// @notice Retry investing pending USDC (e.g. after a stale feed recovered). Anyone may call.
    function invest(address agent) external {
        if (!ruleOf[agent].active) revert NoRule();
        _invest(agent);
    }

    /// @notice The agent withdraws USDC cash or stock it holds. `token == usdc` withdraws cash.
    function withdraw(address token, uint256 amount, address to) external {
        if (token == address(usdc)) {
            if (cashUsdc[msg.sender] < amount) revert Insufficient();
            cashUsdc[msg.sender] -= amount;
        } else {
            if (rawHeld[msg.sender][token] < amount) revert Insufficient();
            rawHeld[msg.sender][token] -= amount;
        }
        if (!IERC20Min(token).transfer(to, amount)) revert TransferFailed();
        emit Withdrawn(msg.sender, token, amount, to);
    }

    // ---------------------------------------------------------------- views

    function basket(address agent) external view returns (Leg[] memory) {
        return basketOf[agent];
    }

    function holdingsOf(address agent) external view returns (Holding[] memory out) {
        Leg[] memory legs = basketOf[agent];
        out = new Holding[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            address t = legs[i].token;
            uint256 raw = rawHeld[agent][t];
            (uint256 price,) = _nav(t);
            out[i] = Holding(t, raw, raw == 0 ? 0 : IB20Asset(t).toUIAmount(raw), raw * price / 1e10);
        }
    }

    // ---------------------------------------------------------------- internals

    /// NAV price per token, 8 decimals (total return: already includes the multiplier), and its age.
    function _nav(address token) internal view returns (uint256 price, uint256 age) {
        INavFeed f = INavFeed(navFeedOf[token]);
        (, int256 answer,, uint256 updatedAt,) = f.latestRoundData();
        if (answer <= 0 || f.decimals() != 8) return (0, type(uint256).max);
        price = uint256(answer);
        age = block.timestamp - updatedAt;
    }

    function _invest(address agent) internal {
        uint256 budget = pendingUsdc[agent];
        if (budget == 0) return;
        Rule memory r = ruleOf[agent];
        Leg[] memory legs = basketOf[agent];
        // Check every leg first: buy all or nothing, so the basket weights stay right.
        uint256[] memory minOut = new uint256[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            (uint256 price, uint256 age) = _nav(legs[i].token);
            if (price == 0 || age > MAX_NAV_AGE) {
                emit BuyDeferred(agent, legs[i].token, "nav stale");
                return;
            }
            if (IB20Asset(legs[i].token).isPaused(IB20.PausableFeature.TRANSFER)) {
                emit BuyDeferred(agent, legs[i].token, "transfers paused");
                return;
            }
            uint256 legUsdc = budget * legs[i].weightBps / 10_000;
            // USDC (6 dp) → token (8 dp) at NAV, minus the slippage allowance
            minOut[i] = legUsdc * 1e10 / price * (10_000 - r.maxSlippageBps) / 10_000;
        }
        pendingUsdc[agent] = 0;
        uint256 spent;
        for (uint256 i; i < legs.length; i++) {
            uint256 legUsdc = i == legs.length - 1 ? budget - spent : budget * legs[i].weightBps / 10_000;
            spent += legUsdc;
            usdc.approve(address(adapter), legUsdc);
            uint256 before = IERC20Min(legs[i].token).balanceOf(address(this));
            adapter.swapExactIn(address(usdc), legs[i].token, legUsdc, minOut[i], address(this));
            uint256 got = IERC20Min(legs[i].token).balanceOf(address(this)) - before;
            if (got < minOut[i]) revert Insufficient();
            rawHeld[agent][legs[i].token] += got;
            emit Bought(agent, legs[i].token, legUsdc, got, IB20Asset(legs[i].token).toUIAmount(got));
        }
    }
}
