// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface ITeaVaultAlgebraV1Point9 {

    error PoolNotInitialized();
    error InvalidFeeCap();
    error InvalidFeePercentage();
    error InvalidShareAmount();
    error InvalidPriceSlippage(uint256 amount0, uint256 amount1);
    error PositionLengthExceedsLimit();
    error PositionDoesNotExist();
    error InvalidCallbackStatus();
    error InvalidCallbackCaller();
    error SwapInZeroLiquidityRegion();
    error WorseRate(uint256 baselineAmount, uint256 receivedAmount);
    error InsufficientSwapResult(uint256 minReceivedAmount, uint256 receivedAmount);
    error ZeroAddress();
    error CallerIsNotManager();
    error ZeroShares();
    error ZeroLiquidity();
    error TransactionExpired();

    event TeaVaultAlgebraV1Point9(address indexed deployedAddress);
    event ManagerChanged(address indexed sender, address indexed newManager);
    event FeeConfigChanged(address indexed sender, uint256 timestamp, FeeConfig feeConfig);
    event DepositShares(address indexed shareOwner, uint256 shares, uint256 amount0, uint256 amount1, uint256 feeAmount0, uint256 feeAmount1);
    event WithdrawShares(address indexed shareOwner, uint256 shares, uint256 amount0, uint256 amount1, uint256 feeShares);
    event AddLiquidity(address indexed pool, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1);
    event RemoveLiquidity(address indexed pool, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Collect(address indexed pool, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);
    event CollectSwapFees(address indexed pool, uint256 amount0, uint256 amount1, uint256 feeAmount0, uint256 feeAmount1);
    event ManagementFeeCollected(uint256 shares);
    event Swap(address indexed manager, ERC20Upgradeable indexed srcToken, ERC20Upgradeable indexed dstToken, uint256 timestamp, address router, uint256 amountPaid, uint256 amountReceived);

    /// @notice Fee config structure
    /// @param treasury Fee goes to this address
    /// @param entryFee Entry fee in 0.0001% (collected when depositing)
    /// @param exitFee Exit fee in 0.0001% (collected when withdrawing)
    /// @param performanceFee Platform performance fee in 0.0001% (collected for each cycle, from profits)
    /// @param managementFee Platform yearly management fee in 0.0001% (collected when depositing/withdrawing)
    struct FeeConfig {
        address treasury;
        uint24 entryFee;
        uint24 exitFee;
        uint24 performanceFee;
        uint24 managementFee;
    }

    /// @notice Position structure
    /// @param tickLower Tick lower bound
    /// @param tickUpper Tick upper bound
    /// @param liquidity Liquidity size
    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice Pause deposit and withdraw for this vault
    function pause() external;

    /// @notice Unpause deposit and withdraw for this vault
    function unpause() external;

    /// @notice Pause status check
    /// @return status Paused or not
    function isPaused() external view returns (bool status);

    /// @notice Get asset token0 address
    /// @return token0 Token0 address
    function assetToken0() external view returns (address token0);

    /// @notice Get asset token1 address
    /// @return token1 Token1 address
    function assetToken1() external view returns (address token1);

    /// @notice Assign fund manager
    /// @notice Only available to admins
    /// @param manager Fund manager address
    function assignManager(address manager) external;

    /// @notice Set fee structure and vault addresses
    /// @notice Only available to admins
    /// @param feeConfig Fee structure setting
    function setFeeConfig(FeeConfig calldata feeConfig) external;

    /// @notice Get vault balance of token0
    /// @return balance Vault balance of token0
    function getToken0Balance() external view returns (uint256 balance);

    /// @notice Get vault balance of token1
    /// @return balance Vault balance of token1
    function getToken1Balance() external view returns (uint256 balance);

    /// @notice Get pool token and price info
    /// @return token0 Token0 address
    /// @return token1 Token1 address
    /// @return decimals0 Token0 decimals
    /// @return decimals1 Token1 decimals
    /// @return feeZto Fee rate of swapping token0 for token1
    /// @return feeOtz Fee rate of swapping token1 for token0
    /// @return tickSpacing Pool tick spacing
    /// @return sqrtPriceX96 Current pool square root price in Q64.96
    /// @return tick Current pool price in tick
    function getPoolInfo() external view returns (
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        uint8 decimals0,
        uint8 decimals1,
        uint16 feeZto,
        uint16 feeOtz,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        int24 tick
    );

    /// @notice Mint shares and deposit token0 and token1
    /// @param shares Share amount to be mint
    /// @param amount0Max Maximum token0 amount to be deposited
    /// @param amount1Max Maximum token1 amount to be deposited
    /// @return depositedAmount0 Deposited token0 amount
    /// @return depositedAmount1 Deposited token1 amount
    function deposit(
        uint256 shares,
        uint256 amount0Max,
        uint256 amount1Max
    ) external returns (
        uint256 depositedAmount0,
        uint256 depositedAmount1
    );

    /// @notice Burn shares and withdraw token0 and token1
    /// @param shares Share amount to be burnt
    /// @param amount0Min Minimum token0 amount to be withdrawn
    /// @param amount1Min Minimum token1 amount to be withdrawn
    /// @return withdrawnAmount0 Withdrawn token0 amount
    /// @return withdrawnAmount1 Withdrawn token1 amount
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min
    ) external returns (
        uint256 withdrawnAmount0,
        uint256 withdrawnAmount1
    );

    /// @notice Add liquidity to a position from this vault
    /// @notice Only fund manager can do this
    /// @param tickLower Tick lower bound
    /// @param tickUpper Tick upper bound
    /// @param liquidity Liquidity to be added to the position
    /// @param amount0Min Minimum token0 amount to be added to the position
    /// @param amount1Min Minimum token1 amount to be added to the position
    /// @param deadline Deadline of the transaction (transaction will revert if after this timestamp)
    /// @return amount0 Token0 amount added to the position
    /// @return amount1 Token1 amount added to the position
    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint64 deadline
    ) external returns (
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Remove liquidity from a position from this vault
    /// @notice Only fund manager can do this
    /// @param tickLower Tick lower bound
    /// @param tickUpper Tick upper bound
    /// @param liquidity Liquidity to be removed from the position
    /// @param amount0Min Minimum token0 amount to be removed from the position
    /// @param amount1Min Minimum token1 amount to be removed from the position
    /// @param deadline Deadline of the transaction (transaction will revert if tx happening after this timestamp)
    /// @return amount0 Token0 amount removed from the position
    /// @return amount1 Token1 amount removed from the position
    function removeLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint64 deadline
    ) external returns (
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Collect swap fee of a position
    /// @notice Only fund manager can do this
    /// @param tickLower Tick lower bound
    /// @param tickUpper Tick upper bound
    /// @return amount0 Token0 amount collected from the position
    /// @return amount1 Token1 amount collected from the position
    function collectPositionSwapFee(
        int24 tickLower,
        int24 tickUpper
    ) external returns (
        uint128 amount0,
        uint128 amount1
    );

    /// @notice Collect swap fee of all positions
    /// @notice Only fund manager can do this
    /// @return amount0 Token0 amount collected from the positions
    /// @return amount1 Token1 amount collected from the positions
    function collectAllSwapFee() external returns (uint128 amount0, uint128 amount1);

    /// @notice Collect management fee by share token inflation
    /// @notice Only fund manager can do this
    /// @return collectedShares Share amount collected by minting
    function collectManagementFee() external returns (uint256 collectedShares);

    /// @notice Swap using the pool of the vault
    /// @param zeroForOne Swap direction
    /// @param maxPaidAmount Maximum paid amount
    /// @param minReceivedAmount Minimum received amount
    /// @param deadline Deadline of the transaction (transaction will revert if after this timestamp)
    /// @return paidAmount Paid amount
    /// @return receivedAmount Received amount
    function inPoolSwap(
        bool zeroForOne,
        uint256 maxPaidAmount,
        uint256 minReceivedAmount,
        uint64 deadline
    ) external returns (
        uint256 paidAmount,
        uint256 receivedAmount
    );

    /// @notice Execute swap from any router via swap relayer
    /// @param zeroForOne Swap direction
    /// @param maxPaidAmount Maximum paid amount
    /// @param minReceivedAmount Minimum received amount
    /// @param deadline Deadline of the transaction (transaction will revert if after this timestamp)
    /// @param swapRouter Swap router
    /// @param data Calldata for swap router
    /// @return paidAmount Paid amount
    /// @return receivedAmount Received amount
    function executeSwap(
        bool zeroForOne,
        uint256 maxPaidAmount,
        uint256 minReceivedAmount,
        uint64 deadline,
        address swapRouter,
        bytes calldata data
    ) external returns (
        uint256 paidAmount,
        uint256 receivedAmount
    );

    /// @notice Get position info by specifying tickLower and tickUpper of the position
    /// @param tickLower Tick lower bound
    /// @param tickUpper Tick upper bound
    /// @return amount0 Current position token0 amount
    /// @return amount1 Current position token1 amount
    /// @return fee0 Pending fee token0 amount
    /// @return fee1 Pending fee token1 amount
    function positionInfo(
        int24 tickLower,
        int24 tickUpper
    ) external view returns (
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    );

    /// @notice Get position info by specifying position index
    /// @param index Position index
    /// @return amount0 Current position token0 amount
    /// @return amount1 Current position token1 amount
    /// @return fee0 Pending fee token0 amount
    /// @return fee1 Pending fee token1 amount
    function positionInfo(
        uint256 index
    ) external view returns (
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    );

    /// @notice Get all position info
    /// @return amount0 All positions token0 amount
    /// @return amount1 All positions token1 amount
    /// @return fee0 All positions pending fee token0 amount
    /// @return fee1 All positions pending fee token1 amount
    function allPositionInfo() external view returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);

    /// @notice Get underlying assets hold by this vault
    /// @return amount0 Total token0 amount
    /// @return amount1 Total token1 amount
    function vaultAllUnderlyingAssets() external view returns (uint256 amount0, uint256 amount1);

    /// @notice Get vault value in token0
    /// @return value0 Vault value in token0
    function estimatedValueInToken0() external view returns (uint256 value0);

    /// @notice Get vault value in token1
    /// @return value1 Vault value in token1
    function estimatedValueInToken1() external view returns (uint256 value1);

    /// @notice Calculate liquidity of a position from amount0 and amount1
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param amount0 Amount of token0
    /// @param amount1 Amount of token1
    /// @return liquidity Calculated liquidity 
    function getLiquidityForAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external view returns (
        uint128 liquidity
    );

    /// @notice Calculate amount of tokens required for liquidity of a position
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param liquidity Amount of liquidity
    /// @return amount0 Amount of token0 required
    /// @return amount1 Amount of token1 required
    function getAmountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external view returns (
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Get all open positions
    /// @return results Array of all open positions
    function getAllPositions() external view returns (Position[] memory results);

}