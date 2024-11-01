// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

// import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";

import "../interface/IAlgebraPool.sol";
import "../interface/ITeaVaultAlgebraV1Point9.sol";

library VaultUtils {
    function getLiquidityForAmounts(
        IAlgebraPool _pool,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 _amount0,
        uint256 _amount1
    ) external view returns (
        uint128 liquidity
    ) {
        (uint160 sqrtPriceX96, , , , , , , ) = _pool.globalState();
        
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_tickLower),
            TickMath.getSqrtRatioAtTick(_tickUpper),
            _amount0,
            _amount1
        );
    }

    function getAmountsForLiquidity(
        IAlgebraPool _pool,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity
    ) external view returns (
        uint256 amount0,
        uint256 amount1
    ) {
        (uint160 sqrtPriceX96, , , , , , , ) = _pool.globalState();

        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_tickLower),
            TickMath.getSqrtRatioAtTick(_tickUpper),
            _liquidity
        );
    }

    function positionInfo(
        address _vault,
        IAlgebraPool _pool,
        ITeaVaultAlgebraV1Point9.Position storage _position
    ) external view returns (
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    ) {
        // position key calculation for AlgebraV1.9
        bytes32 positionKey;
        int24 bottomTick = _position.tickLower;
        int24 topTick = _position.tickUpper;
        assembly {
            positionKey := or(shl(24, or(shl(24, _vault), and(bottomTick, 0xFFFFFF))), and(topTick, 0xFFFFFF))
        }

        (uint160 sqrtPriceX96, int24 tick, , , , , , ) = _pool.globalState();
        uint256 feeGrowthGlobal0X128 = _pool.totalFeeGrowth0Token();
        uint256 feeGrowthGlobal1X128 = _pool.totalFeeGrowth1Token();
        (, , uint256 feeGrowthOutside0X128Lower, uint256 feeGrowthOutside1X128Lower, , , , ) = _pool.ticks(_position.tickLower);
        (, , uint256 feeGrowthOutside0X128Upper, uint256 feeGrowthOutside1X128Upper, , , , ) = _pool.ticks(_position.tickUpper);

        (
            uint128 liquidity,
            ,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = _pool.positions(positionKey);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_position.tickLower),
            TickMath.getSqrtRatioAtTick(_position.tickUpper),
            liquidity
        );
        
        fee0 = tokensOwed0 + potisionSwapFee(
            tick,
            _position.tickLower,
            _position.tickUpper,
            liquidity,
            feeGrowthGlobal0X128,
            feeGrowthInside0Last,
            feeGrowthOutside0X128Lower,
            feeGrowthOutside0X128Upper
        );

        fee1 = tokensOwed1 + potisionSwapFee(
            tick,
            _position.tickLower,
            _position.tickUpper,
            liquidity,
            feeGrowthGlobal1X128,
            feeGrowthInside1Last,
            feeGrowthOutside1X128Lower,
            feeGrowthOutside1X128Upper
        );
    }

    function potisionSwapFee(
        int24 _tick,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity,
        uint256 _feeGrowthGlobalX128,
        uint256 _feeGrowthInsideLastX128,
        uint256 _feeGrowthOutsideX128Lower,
        uint256 _feeGrowthOutsideX128Upper
    ) public pure returns (
        uint256 swapFee
    ) {
        unchecked {
            uint256 feeGrowthInsideX128;
            uint256 feeGrowthBelowX128;
            uint256 feeGrowthAboveX128;

            feeGrowthBelowX128 = _tick >= _tickLower?
                _feeGrowthOutsideX128Lower:
                _feeGrowthGlobalX128 - _feeGrowthOutsideX128Lower;
            
            feeGrowthAboveX128 = _tick < _tickUpper?
                _feeGrowthOutsideX128Upper:
                _feeGrowthGlobalX128 - _feeGrowthOutsideX128Upper;

            feeGrowthInsideX128 = _feeGrowthGlobalX128 - feeGrowthBelowX128 - feeGrowthAboveX128;

            swapFee = FullMath.mulDiv(
                feeGrowthInsideX128 - _feeGrowthInsideLastX128,
                _liquidity,
                FixedPoint128.Q128
            );
        }
    }

    function estimatedValueInToken0(
        IAlgebraPool _pool,
        uint256 _amount0,
        uint256 _amount1
    ) external view returns (
        uint256 value0
    ) {
        (uint160 sqrtPriceX96, , , , , , , ) = _pool.globalState();

        value0 = _amount0 + FullMath.mulDiv(
            _amount1,
            FixedPoint96.Q96,
            FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96)
        );
    }

    function estimatedValueInToken1(
        IAlgebraPool _pool,
        uint256 _amount0,
        uint256 _amount1
    ) external view returns (
        uint256 value1
    ) {
        (uint160 sqrtPriceX96, , , , , , , ) = _pool.globalState();

        value1 = _amount1 + FullMath.mulDiv(
            _amount0,
            FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96),
            FixedPoint96.Q96
        );
    }
}