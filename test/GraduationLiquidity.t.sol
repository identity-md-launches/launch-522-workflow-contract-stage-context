// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadIntegrationTest} from "./PvPadIntegration.t.sol";

contract GraduationLiquidityTest is PvPadIntegrationTest {
    using PoolIdLibrary for PoolKey;

    function test_saturatedUpperTicksDoNotBlockPermissionlessGraduationOrSwaps() public {
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        uint256 balanceBefore = trader.balance;
        _addPosition(attackerRouter, upper - 60, upper, Pool.tickSpacingToMaxLiquidityPerTick(60));
        assertLt(balanceBefore - trader.balance, 0.001 ether, "attack only costs dust ETH");

        _graduateAndCheckPosition(lower, upper - 120);
        (BalanceDelta delta, uint256 fee) = _swap(true, -int256(0.1 ether));
        assertGt(delta.amount1(), 0);
        assertEq(fee, 0.001 ether);
        _assertPositionCannotBeRemoved(attackerRouter, lower, upper - 120);
    }

    function test_saturatedLowerTicksDoNotBlockGraduation() public {
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        IERC20 token = _fundTokenPosition(attackerRouter);
        uint256 balanceBefore = token.balanceOf(trader);
        _addPosition(attackerRouter, lower, lower + 60, Pool.tickSpacingToMaxLiquidityPerTick(60));
        assertLt(balanceBefore - token.balanceOf(trader), 0.001 ether, "attack only costs dust tokens");

        _graduateAndCheckPosition(lower + 120, upper);
        _assertPositionCannotBeRemoved(attackerRouter, lower + 120, upper);
    }

    function test_multipleSaturatedTicksAtBothEndsAreSkipped() public {
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        _fundTokenPosition(attackerRouter);
        uint128 maximum = Pool.tickSpacingToMaxLiquidityPerTick(60);
        _addPosition(attackerRouter, lower, lower + 60, maximum);
        _addPosition(attackerRouter, lower + 120, lower + 180, maximum);
        _addPosition(attackerRouter, upper - 60, upper, maximum);
        _addPosition(attackerRouter, upper - 180, upper - 120, maximum);

        _graduateAndCheckPosition(lower + 240, upper - 240);
    }

    function test_partiallyAvailableTicksAreSkippedWhenRoomIsInsufficient() public {
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        uint128 maximum = Pool.tickSpacingToMaxLiquidityPerTick(60);
        _addPosition(attackerRouter, upper - 60, upper, maximum - 1);
        (uint128 gross,) = StateLibrary.getTickLiquidity(manager, _key(0).toId(), upper);
        assertEq(gross, maximum - 1);

        _graduateAndCheckPosition(lower, upper - 120);
    }

    function test_sharedTicksAreRetainedWhenTheyHaveEnoughRoom() public {
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        PoolModifyLiquidityTest attackerRouter = new PoolModifyLiquidityTest(manager);
        _addPosition(attackerRouter, upper - 60, upper, Pool.tickSpacingToMaxLiquidityPerTick(60) / 2);

        _graduateAndCheckPosition(lower, upper);
    }

    function test_unavailableRangeRollsBackAndCanBeRetried() public {
        (BondingCurve curve, IERC20 token) = _curve(0);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        uint256 tokenReserve = curve.tokenReserve();
        PoolId poolId = _key(0).toId();
        bytes32 slot0 = keccak256(abi.encode(poolId, StateLibrary.POOLS_SLOT));
        bytes32 originalSlot0 = manager.extsload(slot0);
        // Model every boundary being full while preserving the actual canonical pool price.
        bytes4 selector = bytes4(keccak256("extsload(bytes32)"));
        vm.mockCall(
            address(manager), abi.encodeWithSelector(selector), abi.encode(Pool.tickSpacingToMaxLiquidityPerTick(60))
        );
        vm.mockCall(address(manager), abi.encodeWithSelector(selector, slot0), abi.encode(originalSlot0));
        vm.expectRevert(PvPadFactory.LiquidityRangeUnavailable.selector);
        factory.graduate(0);
        vm.clearMockedCalls();

        assertFalse(curve.graduated());
        assertFalse(factory.isRegisteredPool(poolId));
        assertEq(curve.ethReserve(), 4.2 ether);
        assertEq(address(curve).balance, 4.2 ether);
        assertEq(curve.tokenReserve(), tokenReserve);
        assertEq(token.balanceOf(address(curve)), tokenReserve);
        assertEq(factory.lockedLiquidity(0), 0);
        vm.prank(address(0x1234));
        factory.graduate(0);
        assertTrue(curve.graduated());
    }

    function _fundTokenPosition(PoolModifyLiquidityTest attackerRouter) private returns (IERC20 token) {
        BondingCurve curve;
        (curve, token) = _curve(0);
        vm.startPrank(trader);
        curve.buy{value: 0.01 ether}(trader, 1, block.timestamp);
        token.approve(address(attackerRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _addPosition(PoolModifyLiquidityTest attackerRouter, int24 lower, int24 upper, uint128 liquidity) private {
        PoolKey memory key = _key(0);
        vm.prank(trader);
        attackerRouter.modifyLiquidity{value: 0.001 ether}(
            key, IPoolManager.ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0)), ""
        );
    }

    function _graduateAndCheckPosition(int24 lower, int24 upper) private {
        (BondingCurve curve, IERC20 token) = _curve(0);
        vm.prank(trader);
        curve.buy{value: 5 ether}(trader, 1, block.timestamp);
        assertTrue(curve.readyToGraduate());
        vm.prank(address(0x1234));
        factory.graduate(0);

        PoolKey memory key = _key(0);
        assertTrue(curve.graduated());
        assertTrue(factory.isRegisteredPool(key.toId()));
        assertEq(curve.ethReserve(), 0);
        assertEq(curve.tokenReserve(), 0);
        assertEq(factory.lockedTickLower(0), lower);
        assertEq(factory.lockedTickUpper(0), upper);
        (uint128 locked,,) =
            StateLibrary.getPositionInfo(manager, key.toId(), address(factory), lower, upper, bytes32(0));
        assertGt(locked, 0);
        assertEq(locked, factory.lockedLiquidity(0));
        assertEq(locked, StateLibrary.getLiquidity(manager, key.toId()));
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function _assertPositionCannotBeRemoved(PoolModifyLiquidityTest attackerRouter, int24 lower, int24 upper) private {
        PoolKey memory key = _key(0);
        uint128 locked = factory.lockedLiquidity(0);
        vm.expectRevert();
        attackerRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(lower, upper, -int256(uint256(locked)), bytes32(0)), ""
        );
        (uint128 afterAttempt,,) =
            StateLibrary.getPositionInfo(manager, key.toId(), address(factory), lower, upper, bytes32(0));
        assertEq(afterAttempt, locked);
    }
}
