// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {IB20} from "base-std/interfaces/IB20.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function decimals() external view returns (uint8);
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
///      `depositEarning`. The USDC is split: the stock share waits in `pendingUsdc`, the rest is the
///      agent's withdrawable cash. A payment never fails because of a buy: if buying is not possible
///      right now, the USDC simply stays pending.
///   3. Once the pending amount reaches `minBuyUsdc`, the treasury buys every basket leg through the
///      swap adapter, with a minimum output from the stock's NAV feed and the agent's slippage cap.
///      All legs or none. Stale or missing NAV, paused transfers, or a venue below NAV minus slippage
///      all defer the buy.
///   4. Holdings are tracked per agent in raw token units and reported as share-equivalent units
///      (B20 `toUIAmount`, which follows splits and reinvested dividends) and as USD at NAV.
///
/// The operator lists stocks (with their NAV feeds) and chooses the venue; both changes take effect only
/// after a 2-day delay, so an agent can move pending USDC back to cash (`cancelPending`) or withdraw
/// before a change it doesn't trust. Cash and stock already bought are only ever moved by the agent.
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
        uint16 maxSlippageBps; // vs NAV, ≤ 500
        uint64 minBuyUsdc; // batch small earnings until at least this much is pending
        bool active;
    }

    struct Holding {
        address token;
        uint256 raw; // token units (8 decimals for Coinbase stocks)
        uint256 shares; // share-equivalent units: raw × uiMultiplier
        uint256 usdValue; // 6 decimals, at NAV
    }

    struct Pending {
        address target; // token (stock change) or adapter
        address feed; // for a stock change; address(0) = delist
        uint64 eta;
    }

    uint256 public constant MAX_LEGS = 5;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    /// Feeds update at least daily on market days and pause over weekends: allow a long weekend.
    uint256 public constant MAX_NAV_AGE = 80 hours;
    uint256 public constant CHANGE_DELAY = 2 days;

    IERC20Min public immutable usdc;
    address public owner;
    address public pendingOwner;
    ISwapAdapter public adapter;
    Pending public pendingAdapter;
    mapping(address token => Pending) public pendingListing;

    mapping(address token => address feed) public navFeedOf; // listed stocks and their NAV feeds
    mapping(address agent => Rule) public ruleOf;
    mapping(address agent => Leg[]) internal basketOf;
    mapping(address agent => address[]) internal heldTokens; // every stock the agent ever held
    mapping(address agent => mapping(address token => bool)) internal isHeld;
    mapping(address agent => uint256) public pendingUsdc; // waiting to be invested
    mapping(address agent => uint256) public cashUsdc; // not invested, withdrawable
    mapping(address agent => mapping(address token => uint256)) public rawHeld;

    uint256 private locked = 1;

    event RuleSet(address indexed agent, uint16 shareBps, uint16 maxSlippageBps, uint64 minBuyUsdc, uint256 legs);
    event EarningDeposited(
        address indexed agent, address indexed payer, uint256 amount, uint256 toStocks, bytes32 jobRef
    );
    event Bought(address indexed agent, address indexed token, uint256 usdcIn, uint256 rawOut, uint256 sharesOut);
    event BuyDeferred(address indexed agent, address indexed token, string reason);
    event PendingCancelled(address indexed agent, uint256 amount);
    event Withdrawn(address indexed agent, address indexed token, uint256 amount, address to);
    event StockListingProposed(address indexed token, address feed, uint64 eta);
    event StockListed(address indexed token, address feed);
    event AdapterProposed(address adapter, uint64 eta);
    event AdapterSet(address adapter);
    event OwnershipTransferred(address from, address to);

    error NotOwner();
    error BadRule();
    error BadListing();
    error NoRule();
    error TooEarly();
    error TransferFailed();
    error Insufficient();
    error Reentrant();
    error OnlySelf();
    error OutOfGasForBuy();

    constructor(IERC20Min usdc_, ISwapAdapter adapter_, address[] memory tokens, address[] memory feeds) {
        usdc = usdc_;
        owner = msg.sender;
        adapter = adapter_;
        emit AdapterSet(address(adapter_));
        if (tokens.length != feeds.length) revert BadListing();
        // initial listing at deployment, no delay
        for (uint256 i; i < tokens.length; i++) {
            _list(tokens[i], feeds[i]);
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrant();
        locked = 2;
        _;
        locked = 1;
    }

    // ---------------------------------------------------------------- operator (time-locked)

    /// @notice Propose listing (or, with feed = 0, delisting) a stock. Takes effect after CHANGE_DELAY.
    function proposeListing(address token, address feed) external onlyOwner {
        uint64 eta = uint64(block.timestamp + CHANGE_DELAY);
        pendingListing[token] = Pending(token, feed, eta);
        emit StockListingProposed(token, feed, eta);
    }

    function executeListing(address token) external onlyOwner {
        Pending memory p = pendingListing[token];
        if (p.eta == 0 || block.timestamp < p.eta) revert TooEarly();
        delete pendingListing[token];
        _list(token, p.feed);
    }

    function proposeAdapter(ISwapAdapter adapter_) external onlyOwner {
        uint64 eta = uint64(block.timestamp + CHANGE_DELAY);
        pendingAdapter = Pending(address(adapter_), address(0), eta);
        emit AdapterProposed(address(adapter_), eta);
    }

    function executeAdapter() external onlyOwner {
        Pending memory p = pendingAdapter;
        if (p.eta == 0 || block.timestamp < p.eta) revert TooEarly();
        delete pendingAdapter;
        adapter = ISwapAdapter(p.target);
        emit AdapterSet(p.target);
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---------------------------------------------------------------- agent

    /// @notice The agent sets its own investing rule. Weights must sum to 100% over listed stocks.
    function setRule(uint16 shareBps, uint16 maxSlippageBps, uint64 minBuyUsdc, Leg[] calldata legs)
        external
        nonReentrant
    {
        if (shareBps > 10_000 || maxSlippageBps > MAX_SLIPPAGE_BPS || legs.length == 0 || legs.length > MAX_LEGS) {
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

    /// @notice Pays `amount` USDC to `agent` through its treasury (pulls from msg.sender). Never reverts
    ///         because of a failed buy: the stock share then stays pending.
    /// @param jobRef  the BotHire job this earning comes from, for the audit trail.
    function depositEarning(address agent, uint256 amount, bytes32 jobRef) external nonReentrant {
        Rule memory r = ruleOf[agent];
        if (!r.active) revert NoRule();
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        uint256 toStocks = amount * r.shareBps / 10_000;
        pendingUsdc[agent] += toStocks;
        cashUsdc[agent] += amount - toStocks;
        emit EarningDeposited(agent, msg.sender, amount, toStocks, jobRef);
        _tryInvest(agent);
    }

    /// @notice The agent (only) retries investing its pending USDC, e.g. after a stale feed recovered.
    function invest() external nonReentrant {
        if (!ruleOf[msg.sender].active) revert NoRule();
        _tryInvest(msg.sender);
    }

    /// @notice The agent moves its pending USDC back to withdrawable cash.
    function cancelPending() external nonReentrant {
        uint256 p = pendingUsdc[msg.sender];
        pendingUsdc[msg.sender] = 0;
        cashUsdc[msg.sender] += p;
        emit PendingCancelled(msg.sender, p);
    }

    /// @notice The agent withdraws USDC cash or stock it holds. `token == usdc` withdraws cash.
    function withdraw(address token, uint256 amount, address to) external nonReentrant {
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

    /// @dev External only so it can be wrapped in try/catch; callable by this contract alone.
    ///      If anything inside reverts, every state change it made is rolled back with it.
    function investFor(address agent) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _invest(agent);
    }

    // ---------------------------------------------------------------- views

    function basket(address agent) external view returns (Leg[] memory) {
        return basketOf[agent];
    }

    /// @notice Every stock the agent holds or held, including ones no longer in its basket.
    function holdingsOf(address agent) external view returns (Holding[] memory out) {
        address[] memory ts = heldTokens[agent];
        out = new Holding[](ts.length);
        for (uint256 i; i < ts.length; i++) {
            uint256 raw = rawHeld[agent][ts[i]];
            (uint256 price,) = _nav(ts[i]);
            out[i] = Holding(ts[i], raw, raw == 0 ? 0 : IB20Asset(ts[i]).toUIAmount(raw), raw * price / 1e10);
        }
    }

    // ---------------------------------------------------------------- internals

    function _list(address token, address feed) internal {
        if (token == address(0) || token == address(usdc)) revert BadListing();
        if (feed != address(0) && IERC20Min(token).decimals() != 8) revert BadListing();
        navFeedOf[token] = feed;
        emit StockListed(token, feed);
    }

    /// NAV price per token (8 decimals, total return: already includes the multiplier) and its age.
    /// A missing, broken, negative or future-dated feed reads as "stale" instead of reverting.
    function _nav(address token) internal view returns (uint256 price, uint256 age) {
        address f = navFeedOf[token];
        if (f == address(0)) return (0, type(uint256).max);
        try INavFeed(f).decimals() returns (uint8 d) {
            if (d != 8) return (0, type(uint256).max);
        } catch {
            return (0, type(uint256).max);
        }
        try INavFeed(f).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt > block.timestamp) return (0, type(uint256).max);
            return (uint256(answer), block.timestamp - updatedAt);
        } catch {
            return (0, type(uint256).max);
        }
    }

    function _tryInvest(address agent) internal {
        uint256 p = pendingUsdc[agent];
        if (p == 0 || p < ruleOf[agent].minBuyUsdc) return;
        uint256 gasBefore = gasleft();
        try this.investFor(agent) {}
        catch {
            // If the buy failed only because it ran out of gas, fail the whole call instead of deferring:
            // otherwise eth_estimateGas would settle on a limit that always skips the buy. (After an
            // out-of-gas, only the 1/64 of gas kept back by the call is left.)
            if (gasleft() <= gasBefore / 63) revert OutOfGasForBuy();
            emit BuyDeferred(agent, address(0), "buy failed; USDC stays pending");
        }
    }

    function _invest(address agent) internal {
        uint256 budget = pendingUsdc[agent];
        Rule memory r = ruleOf[agent];
        Leg[] memory legs = basketOf[agent];
        // Check every leg first: buy all or nothing, so the basket weights stay right.
        uint256[] memory minOut = new uint256[](legs.length);
        uint256[] memory legUsdc = new uint256[](legs.length);
        uint256 assigned;
        for (uint256 i; i < legs.length; i++) {
            (uint256 price, uint256 age) = _nav(legs[i].token);
            if (price == 0 || age > MAX_NAV_AGE) {
                emit BuyDeferred(agent, legs[i].token, "nav stale or missing");
                return;
            }
            if (IB20Asset(legs[i].token).isPaused(IB20.PausableFeature.TRANSFER)) {
                emit BuyDeferred(agent, legs[i].token, "transfers paused");
                return;
            }
            legUsdc[i] = i == legs.length - 1 ? budget - assigned : budget * legs[i].weightBps / 10_000;
            assigned += legUsdc[i];
            // USDC (6 dp) → token (8 dp) at NAV, minus the slippage allowance
            minOut[i] = legUsdc[i] * 1e10 * (10_000 - r.maxSlippageBps) / 10_000 / price;
            if (minOut[i] == 0) {
                emit BuyDeferred(agent, legs[i].token, "leg too small");
                return;
            }
        }
        pendingUsdc[agent] = 0;
        uint256 refund;
        for (uint256 i; i < legs.length; i++) {
            address t = legs[i].token;
            if (!usdc.approve(address(adapter), legUsdc[i])) revert TransferFailed();
            uint256 usdcBefore = usdc.balanceOf(address(this));
            uint256 before = IERC20Min(t).balanceOf(address(this));
            adapter.swapExactIn(address(usdc), t, legUsdc[i], minOut[i], address(this));
            uint256 got = IERC20Min(t).balanceOf(address(this)) - before;
            uint256 spent = usdcBefore - usdc.balanceOf(address(this));
            if (got < minOut[i] || spent > legUsdc[i]) revert Insufficient();
            refund += legUsdc[i] - spent; // anything the venue didn't take goes back to pending
            if (!usdc.approve(address(adapter), 0)) revert TransferFailed();
            rawHeld[agent][t] += got;
            if (!isHeld[agent][t]) {
                isHeld[agent][t] = true;
                heldTokens[agent].push(t);
            }
            emit Bought(agent, t, spent, got, IB20Asset(t).toUIAmount(got));
        }
        pendingUsdc[agent] += refund;
    }
}
