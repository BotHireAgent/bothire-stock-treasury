// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "base-std-test/lib/BaseTest.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {AgentStockTreasury, ISwapAdapter, IERC20Min, INavFeed} from "../src/AgentStockTreasury.sol";
import {MirroredNavFeed} from "../src/mocks/MirroredNavFeed.sol";
import {NavSwapVenue} from "../src/mocks/NavSwapVenue.sol";

contract TestUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Fills honestly but tries to re-enter the treasury during the swap (a malicious venue).
contract ReentrantVenue is ISwapAdapter {
    NavSwapVenue inner;
    AgentStockTreasury public treasury;
    bool public reentered;
    bool public reentryBlocked;

    constructor(NavSwapVenue inner_) {
        inner = inner_;
    }

    function setTreasury(AgentStockTreasury t) external {
        treasury = t;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256)
    {
        if (!reentered) {
            reentered = true;
            try treasury.depositEarning(address(this), 1, "x") {}
            catch {
                reentryBlocked = true;
            }
        }
        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20Min(tokenIn).approve(address(inner), amountIn);
        return inner.swapExactIn(tokenIn, tokenOut, amountIn, minOut, recipient);
    }
}

/// Takes only half of the USDC it is offered.
contract HalfPullVenue is ISwapAdapter {
    NavSwapVenue inner;

    constructor(NavSwapVenue inner_) {
        inner = inner_;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256)
    {
        uint256 half = amountIn / 2;
        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), half);
        IERC20Min(tokenIn).approve(address(inner), half);
        return inner.swapExactIn(tokenIn, tokenOut, half, minOut / 2, recipient);
    }
}

/// Burns ~400k gas per leg before filling, like a multi-hop DEX route.
contract HeavyVenue is ISwapAdapter {
    NavSwapVenue inner;
    uint256 public sink;

    constructor(NavSwapVenue inner_) {
        inner = inner_;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256)
    {
        for (uint256 i; i < 18; i++) {
            sink = uint256(keccak256(abi.encode(sink, i))); // ~22k gas each (fresh SSTORE pattern)
        }
        uint256 g = gasleft();
        while (g - gasleft() < 300_000) {
            sink++;
        }
        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20Min(tokenIn).approve(address(inner), amountIn);
        return inner.swapExactIn(tokenIn, tokenOut, amountIn, minOut, recipient);
    }
}

/// Reverts with a huge payload ("revert bomb").
contract RevertBombVenue is ISwapAdapter {
    function swapExactIn(address, address, uint256, uint256, address) external pure returns (uint256) {
        assembly {
            revert(0, 1000000)
        }
    }
}

/// Takes 99% of the USDC it is offered and still delivers at least minOut.
contract MostlyPullVenue is ISwapAdapter {
    NavSwapVenue inner;

    constructor(NavSwapVenue inner_) {
        inner = inner_;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256)
    {
        uint256 take = amountIn * 99 / 100;
        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), take);
        IERC20Min(tokenIn).approve(address(inner), take);
        return inner.swapExactIn(tokenIn, tokenOut, take, minOut, recipient);
    }
}

contract TreasuryTest is BaseTest {
    TestUSDC usdc;
    AgentStockTreasury treasury;
    NavSwapVenue venue;
    IB20Asset nvda;
    IB20Asset aapl;
    MirroredNavFeed nvdaFeed;
    MirroredNavFeed aaplFeed;
    address agent = address(0xA9E);
    address settler = address(0x5E7);

    function _stock(string memory name, string memory symbol, bytes32 salt) internal returns (IB20Asset t) {
        B20FactoryLib.B20AssetRoleHolders memory roles;
        roles.minter = admin;
        roles.operator = admin;
        roles.pauser = admin;
        roles.unpauser = admin;
        vm.prank(admin);
        t = IB20Asset(
            StdPrecompiles.B20_FACTORY
                .createB20(
                    IB20Factory.B20Variant.ASSET,
                    salt,
                    B20FactoryLib.encodeAssetCreateParams(name, symbol, admin, 8),
                    B20FactoryLib.buildRoleGrants(roles)
                )
        );
    }

    function _deployTreasury(ISwapAdapter a) internal returns (AgentStockTreasury t) {
        address[] memory toks = new address[](2);
        address[] memory feeds = new address[](2);
        (toks[0], feeds[0]) = (address(nvda), address(nvdaFeed));
        (toks[1], feeds[1]) = (address(aapl), address(aaplFeed));
        t = new AgentStockTreasury(IERC20Min(address(usdc)), a, toks, feeds);
        vm.prank(settler);
        usdc.approve(address(t), type(uint256).max);
    }

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        usdc = new TestUSDC();
        nvda = _stock("NVIDIA (test token, not a security)", "tNVDAc", "nvda");
        aapl = _stock("Apple (test token, not a security)", "tAAPLc", "aapl");
        nvdaFeed = new MirroredNavFeed("NVDA NAV (mirror)", address(0x04689a41629776563E6822F76f2e57D148d28513));
        aaplFeed = new MirroredNavFeed("AAPL NAV (mirror)", address(0x787f13dEa48Db0897CbCDD985de77809D837F988));
        nvdaFeed.mirror(151_53047041, block.timestamp - 1 hours); // $151.53
        aaplFeed.mirror(355_08359116, block.timestamp - 1 hours); // $355.08

        venue = new NavSwapVenue(30); // 0.30% fee
        venue.list(address(nvda), INavFeed(address(nvdaFeed)));
        venue.list(address(aapl), INavFeed(address(aaplFeed)));
        vm.startPrank(admin);
        IB20(address(nvda)).mint(address(venue), 1_000e8);
        IB20(address(aapl)).mint(address(venue), 1_000e8);
        vm.stopPrank();

        usdc.mint(settler, 1_000e6);
        treasury = _deployTreasury(ISwapAdapter(address(venue)));
    }

    function _rule(address who, AgentStockTreasury t, uint16 share, uint16 slip, uint64 minBuy) internal {
        AgentStockTreasury.Leg[] memory legs = new AgentStockTreasury.Leg[](2);
        legs[0] = AgentStockTreasury.Leg(address(nvda), 6_000);
        legs[1] = AgentStockTreasury.Leg(address(aapl), 4_000);
        vm.prank(who);
        t.setRule(share, slip, minBuy, legs);
    }

    function test_earningIsSplitAndInvestedAtNav() public {
        _rule(agent, treasury, 2_000, 100, 1e6); // 20% to stocks, buy once ≥ $1 is pending
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job-1"); // $10 earned → $2 to stocks
        assertEq(treasury.cashUsdc(agent), 8e6);
        assertEq(treasury.pendingUsdc(agent), 0);
        uint256 expectNvda = uint256(1.2e6) * 1e10 / 151_53047041 * 9_970 / 10_000;
        assertEq(treasury.rawHeld(agent, address(nvda)), expectNvda);
        assertEq(nvda.balanceOf(address(treasury)), expectNvda);
        AgentStockTreasury.Holding[] memory h = treasury.holdingsOf(agent);
        assertEq(h.length, 2);
        assertApproxEqAbs(h[0].usdValue + h[1].usdValue, 2e6 * 9_970 / 10_000, 5); // integer rounding per leg
    }

    function test_smallEarningsAreBatched() public {
        _rule(agent, treasury, 5_000, 100, 5e6);
        vm.startPrank(settler);
        treasury.depositEarning(agent, 4e6, "a");
        treasury.depositEarning(agent, 4e6, "b");
        assertEq(treasury.rawHeld(agent, address(nvda)), 0);
        treasury.depositEarning(agent, 4e6, "c"); // $6 pending → buy
        vm.stopPrank();
        assertEq(treasury.pendingUsdc(agent), 0);
        assertGt(treasury.rawHeld(agent, address(nvda)), 0);
    }

    function test_staleNavDefersBuyAndKeepsUsdc() public {
        _rule(agent, treasury, 2_000, 100, 1e6);
        aaplFeed.mirror(355_08359116, block.timestamp - 81 hours);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        assertEq(treasury.pendingUsdc(agent), 2e6);
        assertEq(treasury.rawHeld(agent, address(nvda)), 0, "all-or-nothing: no leg bought");
        aaplFeed.mirror(355_08359116, block.timestamp);
        vm.prank(agent);
        treasury.invest();
        assertEq(treasury.pendingUsdc(agent), 0);
        assertGt(treasury.rawHeld(agent, address(aapl)), 0);
    }

    function test_pausedTokenDefersBuy() public {
        _rule(agent, treasury, 2_000, 100, 1e6);
        IB20.PausableFeature[] memory f = new IB20.PausableFeature[](1);
        f[0] = IB20.PausableFeature.TRANSFER;
        vm.prank(admin);
        IB20(address(nvda)).pause(f);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        assertEq(treasury.pendingUsdc(agent), 2e6);
    }

    function test_badVenueDefersButPaymentSucceeds() public {
        NavSwapVenue greedy = new NavSwapVenue(500); // 5% fee, beyond the 1% cap
        greedy.list(address(nvda), INavFeed(address(nvdaFeed)));
        greedy.list(address(aapl), INavFeed(address(aaplFeed)));
        AgentStockTreasury t = _deployTreasury(ISwapAdapter(address(greedy)));
        _rule(agent, t, 2_000, 100, 1e6);
        vm.prank(settler);
        t.depositEarning(agent, 10e6, "job"); // does not revert
        assertEq(t.cashUsdc(agent), 8e6);
        assertEq(t.pendingUsdc(agent), 2e6, "buy rolled back, USDC still pending");
        assertEq(t.rawHeld(agent, address(nvda)), 0);
    }

    /// Regression (found on Base Sepolia): with a tight gas limit the buy must not be silently skipped,
    /// or eth_estimateGas settles on a limit at which buys never happen.
    function test_lowGasRevertsInsteadOfSkippingTheBuy() public {
        _rule(agent, treasury, 2_000, 100, 1e6);
        vm.prank(settler);
        (bool ok,) = address(treasury).call{gas: 200_000}(
            abi.encodeCall(AgentStockTreasury.depositEarning, (agent, 10e6, bytes32("job")))
        );
        assertFalse(ok, "must revert, not defer");
        assertEq(treasury.cashUsdc(agent), 0);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        assertGt(treasury.rawHeld(agent, address(nvda)), 0);
    }

    function test_reentrantVenueCannotDoubleCredit() public {
        ReentrantVenue bad = new ReentrantVenue(venue);
        AgentStockTreasury t = _deployTreasury(ISwapAdapter(address(bad)));
        bad.setTreasury(t);
        _rule(agent, t, 2_000, 100, 1e6);
        _rule(address(bad), t, 10_000, 100, 0);
        usdc.mint(address(bad), 10);
        vm.prank(address(bad));
        usdc.approve(address(t), type(uint256).max);
        vm.prank(settler);
        t.depositEarning(agent, 10e6, "job");
        assertTrue(bad.reentered() && bad.reentryBlocked(), "re-entry must be refused");
        assertEq(nvda.balanceOf(address(t)), t.rawHeld(agent, address(nvda)), "credited == held");
    }

    function test_partialPullIsRolledBack() public {
        HalfPullVenue half = new HalfPullVenue(venue);
        AgentStockTreasury t = _deployTreasury(ISwapAdapter(address(half)));
        _rule(agent, t, 2_000, 100, 1e6);
        vm.prank(settler);
        t.depositEarning(agent, 10e6, "job");
        // each leg got half its minOut, so the whole buy is rolled back and nothing is lost
        assertEq(t.pendingUsdc(agent), 2e6);
        assertEq(usdc.balanceOf(address(t)), 10e6);
    }

    function test_dividendRaisesShareEquivalentsNotRaw() public {
        _rule(agent, treasury, 10_000, 100, 1e6);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        uint256 raw = treasury.rawHeld(agent, address(nvda));
        uint256 sharesBefore = treasury.holdingsOf(agent)[0].shares;
        vm.prank(admin);
        nvda.updateUIMultiplier(1.02e18, block.timestamp + 60);
        vm.warp(block.timestamp + 61);
        AgentStockTreasury.Holding memory h = treasury.holdingsOf(agent)[0];
        assertEq(h.raw, raw);
        assertApproxEqRel(h.shares, sharesBefore * 102 / 100, 1e14);
    }

    function test_agentWithdrawsCashAndStock_othersCannot() public {
        _rule(agent, treasury, 5_000, 100, 1e6);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        uint256 raw = treasury.rawHeld(agent, address(nvda));
        vm.prank(settler);
        vm.expectRevert(AgentStockTreasury.Insufficient.selector);
        treasury.withdraw(address(nvda), raw, settler);
        vm.startPrank(agent);
        treasury.withdraw(address(nvda), raw, agent);
        treasury.withdraw(address(usdc), 5e6, agent);
        vm.stopPrank();
        assertEq(nvda.balanceOf(agent), raw);
        assertEq(usdc.balanceOf(agent), 5e6);
    }

    function test_cancelPendingAndInvestIsAgentOnly() public {
        _rule(agent, treasury, 2_000, 100, 5e6); // $2 pending stays below the $5 batch
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        vm.prank(settler);
        vm.expectRevert(AgentStockTreasury.NoRule.selector); // a third party can't force a buy
        treasury.invest();
        vm.prank(agent);
        treasury.cancelPending();
        assertEq(treasury.pendingUsdc(agent), 0);
        assertEq(treasury.cashUsdc(agent), 10e6);
    }

    function test_operatorChangesAreTimeLocked() public {
        vm.prank(agent);
        vm.expectRevert(AgentStockTreasury.NotOwner.selector);
        treasury.proposeAdapter(ISwapAdapter(address(0xBAD)));
        treasury.proposeAdapter(ISwapAdapter(address(0xBAD)));
        vm.expectRevert(AgentStockTreasury.TooEarly.selector);
        treasury.executeAdapter();
        vm.warp(block.timestamp + 2 days);
        treasury.executeAdapter();
        assertEq(address(treasury.adapter()), address(0xBAD));
        treasury.proposeListing(address(nvda), address(0));
        vm.expectRevert(AgentStockTreasury.TooEarly.selector);
        treasury.executeListing(address(nvda));
    }

    function test_delistedFeedDoesNotBrickPaymentsOrViews() public {
        _rule(agent, treasury, 2_000, 100, 1e6);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        treasury.proposeListing(address(nvda), address(0));
        vm.warp(block.timestamp + 2 days);
        treasury.executeListing(address(nvda));
        aaplFeed.mirror(355_08359116, block.timestamp);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job2"); // NVDA leg has no feed → deferred, payment ok
        assertEq(treasury.pendingUsdc(agent), 2e6);
        AgentStockTreasury.Holding[] memory h = treasury.holdingsOf(agent); // still readable
        assertEq(h[0].usdValue, 0);
        assertGt(h[0].raw, 0);
    }

    function test_oldHoldingsStayVisibleAfterBasketChange() public {
        _rule(agent, treasury, 10_000, 100, 1e6);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        AgentStockTreasury.Leg[] memory legs = new AgentStockTreasury.Leg[](1);
        legs[0] = AgentStockTreasury.Leg(address(aapl), 10_000);
        vm.prank(agent);
        treasury.setRule(10_000, 100, 1e6, legs);
        AgentStockTreasury.Holding[] memory h = treasury.holdingsOf(agent);
        assertEq(h.length, 2);
        assertEq(h[0].token, address(nvda));
        assertGt(h[0].raw, 0);
    }

    function test_ruleAndListingValidation() public {
        AgentStockTreasury.Leg[] memory legs = new AgentStockTreasury.Leg[](2);
        legs[0] = AgentStockTreasury.Leg(address(nvda), 5_000);
        legs[1] = AgentStockTreasury.Leg(address(nvda), 5_000);
        vm.startPrank(agent);
        vm.expectRevert(AgentStockTreasury.BadRule.selector); // duplicate token
        treasury.setRule(1_000, 100, 1e6, legs);
        legs[1] = AgentStockTreasury.Leg(address(0xBEEF), 5_000);
        vm.expectRevert(AgentStockTreasury.BadRule.selector); // not listed
        treasury.setRule(1_000, 100, 1e6, legs);
        legs[1] = AgentStockTreasury.Leg(address(aapl), 4_000);
        vm.expectRevert(AgentStockTreasury.BadRule.selector); // weights ≠ 100%
        treasury.setRule(1_000, 100, 1e6, legs);
        legs[1] = AgentStockTreasury.Leg(address(aapl), 5_000);
        vm.expectRevert(AgentStockTreasury.BadRule.selector); // slippage cap is 5%
        treasury.setRule(1_000, 600, 1e6, legs);
        vm.stopPrank();
        vm.prank(settler);
        vm.expectRevert(AgentStockTreasury.NoRule.selector);
        treasury.depositEarning(address(0xD00D), 1e6, "x");
        address[] memory toks = new address[](1);
        address[] memory feeds = new address[](1);
        (toks[0], feeds[0]) = (address(usdc), address(nvdaFeed));
        vm.expectRevert(AgentStockTreasury.BadListing.selector); // USDC can't be listed as a stock
        new AgentStockTreasury(IERC20Min(address(usdc)), ISwapAdapter(address(venue)), toks, feeds);
    }

    // ------------------------------------------------------------------ v3: review round 2

    function test_heavyVenueBuysWithEnoughGasAndNeverSilentlySkips() public {
        HeavyVenue heavy = new HeavyVenue(venue);
        AgentStockTreasury t = _deployTreasury(ISwapAdapter(address(heavy)));
        _rule(agent, t, 2_000, 100, 1e6);
        for (uint256 g = 300_000; g <= 1_800_000; g += 300_000) {
            vm.prank(settler);
            (bool ok,) =
                address(t).call{gas: g}(abi.encodeCall(AgentStockTreasury.depositEarning, (agent, 10e6, bytes32("j"))));
            assertFalse(ok, "below the buy budget the payment must revert, not skip the buy");
        }
        vm.prank(settler);
        t.depositEarning{gas: 3_000_000}(agent, 10e6, "j");
        assertGt(t.rawHeld(agent, address(nvda)), 0, "with enough gas the heavy venue fills");
    }

    function test_revertBombVenueOnlyDefers() public {
        AgentStockTreasury t = _deployTreasury(ISwapAdapter(address(new RevertBombVenue())));
        _rule(agent, t, 2_000, 100, 1e6);
        vm.prank(settler);
        t.depositEarning{gas: 5_000_000}(agent, 10e6, "j");
        assertEq(t.cashUsdc(agent), 8e6, "payment went through");
        assertEq(t.pendingUsdc(agent), 2e6, "buy deferred");
    }

    function test_unpulledUsdcIsRefundedToPending() public {
        MostlyPullVenue mostly = new MostlyPullVenue(venue);
        AgentStockTreasury t = _deployTreasury(ISwapAdapter(address(mostly)));
        _rule(agent, t, 2_000, 500, 1e6); // 5% slippage, so 99% of a leg still clears minOut
        vm.prank(settler);
        t.depositEarning(agent, 10e6, "j");
        assertEq(t.pendingUsdc(agent), 2e6 / 100, "1% of the budget came back");
        assertGt(t.rawHeld(agent, address(nvda)), 0);
        assertEq(usdc.allowance(address(t), address(mostly)), 0, "allowance reset");
    }

    function test_zeroDepositRejected() public {
        _rule(agent, treasury, 2_000, 100, 1e6);
        vm.prank(address(0xBAD));
        vm.expectRevert(AgentStockTreasury.ZeroAmount.selector);
        treasury.depositEarning(agent, 0, "fake");
    }

    function test_approvedPayerPolicyControlsWhoTriggersBuys() public {
        _rule(agent, treasury, 2_000, 100, 1e6);
        vm.startPrank(agent);
        treasury.setPayerPolicy(true);
        treasury.setApprovedPayer(settler, true);
        vm.stopPrank();
        address stranger = address(0x57A);
        usdc.mint(stranger, 10e6);
        vm.startPrank(stranger);
        usdc.approve(address(treasury), type(uint256).max);
        treasury.depositEarning(agent, 10e6, "x"); // accepted, but doesn't trigger the buy
        vm.stopPrank();
        assertEq(treasury.pendingUsdc(agent), 2e6);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job"); // approved payer triggers it
        assertEq(treasury.pendingUsdc(agent), 0);
        assertGt(treasury.rawHeld(agent, address(nvda)), 0);
    }

    function test_proposalsExpireAndCanBeCancelled() public {
        treasury.proposeAdapter(ISwapAdapter(address(0xBAD)));
        vm.warp(block.timestamp + 2 days + 7 days + 1);
        vm.expectRevert(AgentStockTreasury.Expired.selector);
        treasury.executeAdapter();
        treasury.proposeListing(address(nvda), address(0));
        treasury.cancelListing(address(nvda));
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(AgentStockTreasury.TooEarly.selector);
        treasury.executeListing(address(nvda));
    }
}
