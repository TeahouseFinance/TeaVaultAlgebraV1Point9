// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface IAlgebraPool {

    function globalState() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 feeZto,
        uint16 feeOtz,
        uint16 timepointIndex,
        uint8 communityFeeToken0,
        uint8 communityFeeToken1,
        bool unlocked
    );

    function ticks(int24 tick) external view returns (
        uint128 liquidityTotal,
        int128 liquidityDelta,
        uint256 outerFeeGrowth0Token,
        uint256 outerFeeGrowth1Token,
        int56 outerTickCumulative,
        uint160 outerSecondsPerLiquidity,
        uint32 outerSecondsSpent,
        bool initialized
    );

    function positions(bytes32 key) external view returns (
        uint128 liquidityAmount,
        uint32 lastLiquidityAddTimestamp,
        uint256 innerFeeGrowth0Token,
        uint256 innerFeeGrowth1Token,
        uint128 fees0,
        uint128 fees1
    );

    function tickSpacing() external view returns (int16);

    function totalFeeGrowth0Token() external view returns (uint256);
    
    function totalFeeGrowth1Token() external view returns (uint256);

    function mint(
        address sender,
        address recipient,
        int24 bottomTick,
        int24 topTick,
        uint128 liquidityDesired,
        bytes calldata data
    ) external returns (
        uint256 amount0,
        uint256 amount1,
        uint128 liquidityActual
    );

    function burn(
        int24 bottomTick,
        int24 topTick,
        uint128 amount
    ) external returns (
        uint256 amount0,
        uint256 amount1
    );

    function collect(
        address recipient,
        int24 bottomTick,
        int24 topTick,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (
        uint128 amount0,
        uint128 amount1
    );

    function swap(
        address recipient,
        bool zeroToOne,
        int256 amountRequired,
        uint160 limitSqrtPrice,
        bytes calldata data
    ) external returns (
        int256 amount0,
        int256 amount1
    );

}