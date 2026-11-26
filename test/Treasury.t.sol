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

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        usdc = new TestUSDC();
        nvda = _stock("NVIDIA (test token, not a security)", "tNVDAc", "nvda");
        aapl = _stock("Apple (test token, not a security)", "tAAPLc", "aapl");
        nvdaFeed = new MirroredNavFeed("Coinbase NVDA (mirror)", address(0x04689a41629776563E6822F76f2e57D148d28513));
        aaplFeed = new MirroredNavFeed("Coinbase AAPL (mirror)", address(0x787f13dEa48Db0897CbCDD985de77809D837F988));
        nvdaFeed.mirror(151_53047041, block.timestamp - 1 hours); // $151.53
        aaplFeed.mirror(355_08359116, block.timestamp - 1 hours); // $355.08

        venue = new NavSwapVenue(30); // 0.30% fee
        venue.list(address(nvda), INavFeed(address(nvdaFeed)));
        venue.list(address(aapl), INavFeed(address(aaplFeed)));
        vm.startPrank(admin);
        IB20(address(nvda)).mint(address(venue), 1_000e8);
        IB20(address(aapl)).mint(address(venue), 1_000e8);
        vm.stopPrank();

        treasury = new AgentStockTreasury(IERC20Min(address(usdc)), ISwapAdapter(address(venue)));
        treasury.listStock(address(nvda), address(nvdaFeed));
        treasury.listStock(address(aapl), address(aaplFeed));

        usdc.mint(settler, 1_000e6);
        vm.prank(settler);
        usdc.approve(address(treasury), type(uint256).max);
    }

    function _rule(uint16 share, uint64 minBuy) internal {
        AgentStockTreasury.Leg[] memory legs = new AgentStockTreasury.Leg[](2);
        legs[0] = AgentStockTreasury.Leg(address(nvda), 6_000);
        legs[1] = AgentStockTreasury.Leg(address(aapl), 4_000);
        vm.prank(agent);
        treasury.setRule(share, 100, minBuy, legs);
    }

    function test_earningIsSplitAndInvestedAtNav() public {
        _rule(2_000, 1e6); // 20% to stocks, buy once ≥ $1 is pending
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job-1"); // $10 earned → $2 to stocks
        assertEq(treasury.cashUsdc(agent), 8e6);
        assertEq(treasury.pendingUsdc(agent), 0);
        // $1.20 of NVDA at $151.53 minus 0.30% fee
        uint256 expectNvda = uint256(1.2e6) * 1e10 / 151_53047041 * 9_970 / 10_000;
        assertEq(treasury.rawHeld(agent, address(nvda)), expectNvda);
        assertEq(nvda.balanceOf(address(treasury)), expectNvda);
        AgentStockTreasury.Holding[] memory h = treasury.holdingsOf(agent);
        assertEq(h.length, 2);
        assertApproxEqAbs(h[0].usdValue + h[1].usdValue, 2e6 * 9_970 / 10_000, 5); // integer rounding per leg
    }

    function test_smallEarningsAreBatched() public {
        _rule(5_000, 5e6); // invest once $5 is pending
        vm.startPrank(settler);
        treasury.depositEarning(agent, 4e6, "a"); // $2 pending
        treasury.depositEarning(agent, 4e6, "b"); // $4 pending
        assertEq(treasury.rawHeld(agent, address(nvda)), 0);
        treasury.depositEarning(agent, 4e6, "c"); // $6 pending → buy
        vm.stopPrank();
        assertEq(treasury.pendingUsdc(agent), 0);
        assertGt(treasury.rawHeld(agent, address(nvda)), 0);
    }

    function test_staleNavDefersBuyAndKeepsUsdc() public {
        _rule(2_000, 1e6);
        aaplFeed.mirror(355_08359116, block.timestamp - 5 days);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        assertEq(treasury.pendingUsdc(agent), 2e6);
        assertEq(treasury.rawHeld(agent, address(nvda)), 0, "all-or-nothing: no leg bought");
        aaplFeed.mirror(355_08359116, block.timestamp);
        treasury.invest(agent);
        assertEq(treasury.pendingUsdc(agent), 0);
        assertGt(treasury.rawHeld(agent, address(aapl)), 0);
    }

    function test_pausedTokenDefersBuy() public {
        _rule(2_000, 1e6);
        vm.prank(admin);
        IB20.PausableFeature[] memory f = new IB20.PausableFeature[](1);
        f[0] = IB20.PausableFeature.TRANSFER;
        IB20(address(nvda)).pause(f);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        assertEq(treasury.pendingUsdc(agent), 2e6);
    }

    function test_venueBelowNavMinusSlippageReverts() public {
        _rule(2_000, 1e6); // 1% slippage cap
        NavSwapVenue greedy = new NavSwapVenue(500); // 5% fee
        greedy.list(address(nvda), INavFeed(address(nvdaFeed)));
        greedy.list(address(aapl), INavFeed(address(aaplFeed)));
        treasury.setAdapter(ISwapAdapter(address(greedy)));
        vm.prank(settler);
        vm.expectRevert();
        treasury.depositEarning(agent, 10e6, "job");
    }

    function test_dividendRaisesSharesNotRaw() public {
        _rule(10_000, 1e6);
        vm.prank(settler);
        treasury.depositEarning(agent, 10e6, "job");
        uint256 raw = treasury.rawHeld(agent, address(nvda));
        uint256 sharesBefore = treasury.holdingsOf(agent)[0].shares;
        vm.prank(admin);
        nvda.updateUIMultiplier(1.02e18, block.timestamp + 60); // a 2% reinvested dividend
        vm.warp(block.timestamp + 61);
        AgentStockTreasury.Holding memory h = treasury.holdingsOf(agent)[0];
        assertEq(h.raw, raw);
        assertApproxEqRel(h.shares, sharesBefore * 102 / 100, 1e14);
    }

    function test_agentWithdrawsCashAndStock_othersCannot() public {
        _rule(5_000, 1e6);
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

    function test_ruleValidation() public {
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
        vm.stopPrank();
        vm.prank(settler);
        vm.expectRevert(AgentStockTreasury.NoRule.selector);
        treasury.depositEarning(address(0xD00D), 1e6, "x");
    }

    function test_onlyOwnerListsAndSetsVenue() public {
        vm.prank(agent);
        vm.expectRevert(AgentStockTreasury.NotOwner.selector);
        treasury.listStock(address(nvda), address(0));
        vm.prank(agent);
        vm.expectRevert(AgentStockTreasury.NotOwner.selector);
        treasury.setAdapter(ISwapAdapter(address(0)));
    }
}
