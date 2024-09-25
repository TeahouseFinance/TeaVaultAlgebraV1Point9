// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {IAlgebraPoolFactory} from "./interface/IAlgebraPoolFactory.sol";
import {IAlgebraPool} from "./interface/IAlgebraPool.sol";
import {ITeaVaultAlgebraV1Point9Factory} from "./interface/ITeaVaultAlgebraV1Point9Factory.sol";
import {ITeaVaultAlgebraV1Point9} from "./interface/ITeaVaultAlgebraV1Point9.sol";
import {ISwapRelayer} from "./interface/ISwapRelayer.sol";
import {VaultUtils} from "./library/VaultUtils.sol";

// import "hardhat/console.sol";

contract TeaVaultAlgebraV1Point9 is
    ITeaVaultAlgebraV1Point9,
    Initializable,
    OwnableUpgradeable,
    ERC20Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20Upgradeable;
    using SafeCast for uint256;
    using FullMath for uint256;

    uint8 internal DECIMALS;
    uint8 internal MAX_POSITION_LENGTH;
    uint256 public SECONDS_IN_A_YEAR;
    uint256 public DECIMALS_MULTIPLIER;
    uint256 public FEE_MULTIPLIER;
    uint256 public FEE_CAP;

    ITeaVaultAlgebraV1Point9Factory public factory;
    ISwapRelayer public swapRelayer;
    IAlgebraPool public pool;
    ERC20Upgradeable private token0;
    ERC20Upgradeable private token1;
    address public manager;
    FeeConfig public feeConfig;
    Position[] public positions;
    uint256 public lastCollectManagementFee;
    uint256 private callbackStatus;

    uint256[34] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // prevent attackers from using implementation contracts
    }

    function initialize(
        address _owner,
        string calldata _name,
        string calldata _symbol,
        uint8 _decimalOffset,
        ISwapRelayer _swapRelayer,
        IAlgebraPoolFactory _poolFactory,
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        address _manager,
        uint24 _feeCap,
        FeeConfig calldata _feeConfig
    ) public initializer {
        _zeroAddressNotAllowed(address(_swapRelayer));
        _zeroAddressNotAllowed(_owner);
        _zeroAddressNotAllowed(_manager);

        __Ownable_init(_owner);
        __ERC20_init(_name, _symbol);
        __Pausable_init();
        __ReentrancyGuard_init();

        (_token0, _token1) = _token0 > _token1 ? (_token1, _token0) : (_token0, _token1);
        IAlgebraPool _pool = _poolFactory.poolByPair(_token0, _token1);
        if (address(_pool) == address(0)) revert PoolNotInitialized();

        DECIMALS = _decimalOffset + _token0.decimals();
        MAX_POSITION_LENGTH = 5;
        SECONDS_IN_A_YEAR = 365 * 24 * 60 * 60;
        DECIMALS_MULTIPLIER = 10 ** _decimalOffset;
        FEE_MULTIPLIER = 1000000;
        if (_feeCap > FEE_MULTIPLIER * 30 / 100) revert InvalidFeeCap();
        FEE_CAP = _feeCap; 

        _assignManager(_manager);
        _setFeeConfig(_feeConfig);

        factory = ITeaVaultAlgebraV1Point9Factory(msg.sender);
        swapRelayer = _swapRelayer;
        pool = _pool;
        token0 = _token0;
        token1 = _token1;
    }

    function decimals() public override view returns (uint8) {
        return DECIMALS;
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function isPaused() external override view returns (bool) {
        return _isPaused();
    }

    function _isPaused() internal view returns (bool) {
        return paused() || factory.isAllVaultsPaused();
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function assetToken0() external view override returns (address) {
        return address(token0);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function assetToken1() external view override returns (address) {
        return address(token1);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function assignManager(address _manager) external override onlyOwner {
        _assignManager(_manager);
    }

    function _assignManager(address _manager) internal {
        _zeroAddressNotAllowed(_manager);
        manager = _manager;

        emit ManagerChanged(msg.sender, _manager);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function setFeeConfig(FeeConfig calldata _feeConfig) external override onlyOwner {
        _collectManagementFee();
        _collectAllSwapFee();
        _setFeeConfig(_feeConfig);
    }

    function _setFeeConfig(FeeConfig calldata _feeConfig) internal {
        _zeroAddressNotAllowed(_feeConfig.treasury);
        uint256 _FEE_CAP = FEE_CAP;
        if (_feeConfig.entryFee + _feeConfig.exitFee > _FEE_CAP) revert InvalidFeePercentage();
        if (_feeConfig.performanceFee > _FEE_CAP) revert InvalidFeePercentage();
        if (_feeConfig.managementFee > _FEE_CAP) revert InvalidFeePercentage();

        feeConfig = _feeConfig;

        emit FeeConfigChanged(msg.sender, block.timestamp, _feeConfig);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function getToken0Balance() external override view returns (uint256 balance) {
        return token0.balanceOf(address(this));
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function getToken1Balance() external override view returns (uint256 balance) {
        return token1.balanceOf(address(this));
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function getPoolInfo() external override view returns (
        ERC20Upgradeable,
        ERC20Upgradeable,
        uint8,
        uint8,
        uint16,
        uint16,
        int24,
        uint160,
        int24
    ) {
        IAlgebraPool _pool = pool;

        (uint160 sqrtPriceX96, int24 tick, uint16 feeZto, uint16 feeOtz, , , , ) = _pool.globalState();
        int24 tickSpacing = _pool.tickSpacing();
        uint8 decimals0 = token0.decimals();
        uint8 decimals1 = token1.decimals();

        return (token0, token1, decimals0, decimals1, feeZto, feeOtz, tickSpacing, sqrtPriceX96, tick);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function deposit(
        uint256 _shares,
        uint256 _amount0Max,
        uint256 _amount1Max
    ) external override nonReentrant onlyNotPaused checkShares(_shares) returns (
        uint256 depositedAmount0,
        uint256 depositedAmount1
    ) {
        _collectManagementFee();
        uint256 totalShares = totalSupply();
        ERC20Upgradeable _token0 = token0;
        ERC20Upgradeable _token1 = token1;

        if (totalShares == 0) {
            // vault is empty, default to 1:1 share to token0 ratio (offseted by _decimalOffset)
            depositedAmount0 = _shares / DECIMALS_MULTIPLIER;
            _token0.safeTransferFrom(msg.sender, address(this), depositedAmount0);
        }
        else {
            _collectAllSwapFee();

            uint256 positionLength = positions.length;
            uint256 amount0;
            uint256 amount1;
            uint128 liquidity;
            
            for (uint256 i; i < positionLength; i++) {
                Position storage position = positions[i];

                liquidity = _fractionOfShares(position.liquidity, _shares, totalShares, true).toUint128();
                (amount0, amount1) = _depositorAddLiquidity(position.tickLower, position.tickUpper, liquidity);

                position.liquidity += liquidity;
                depositedAmount0 += amount0;
                depositedAmount1 += amount1;
            }

            amount0 = _fractionOfShares(_token0.balanceOf(address(this)), _shares, totalShares, true);
            amount1 = _fractionOfShares(_token1.balanceOf(address(this)), _shares, totalShares, true);
            depositedAmount0 += amount0;
            depositedAmount1 += amount1;
            
            _token0.safeTransferFrom(msg.sender, address(this), amount0);
            _token1.safeTransferFrom(msg.sender, address(this), amount1);
        }

        // make sure a user can't make a zero amount deposit
        if (depositedAmount0 == 0 && depositedAmount1 == 0) revert InvalidShareAmount();

        // collect entry fee for users
        // do not collect entry fee for fee recipient
        uint256 entryFeeAmount0;
        uint256 entryFeeAmount1;

        if (msg.sender != feeConfig.treasury) {
            entryFeeAmount0 = _fractionOfFees(depositedAmount0, feeConfig.entryFee);
            entryFeeAmount1 = _fractionOfFees(depositedAmount1, feeConfig.entryFee);

            if (entryFeeAmount0 > 0) {
                _token0.safeTransferFrom(msg.sender, feeConfig.treasury, entryFeeAmount0);
            }
            if (entryFeeAmount1 > 0) {
                _token1.safeTransferFrom(msg.sender, feeConfig.treasury, entryFeeAmount1);
            }
            depositedAmount0 += entryFeeAmount0;
            depositedAmount1 += entryFeeAmount1;
        }

        if (depositedAmount0 > _amount0Max || depositedAmount1 > _amount1Max) revert InvalidPriceSlippage(depositedAmount0, depositedAmount1);
        _mint(msg.sender, _shares);

        emit DepositShares(msg.sender, _shares, depositedAmount0, depositedAmount1, entryFeeAmount0, entryFeeAmount1);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function withdraw(
        uint256 _shares,
        uint256 _amount0Min,
        uint256 _amount1Min
    ) external override nonReentrant onlyNotPaused checkShares(_shares) returns (
        uint256 withdrawnAmount0,
        uint256 withdrawnAmount1
    ) {
        _collectManagementFee();
        uint256 totalShares = totalSupply();
        ERC20Upgradeable _token0 = token0;
        ERC20Upgradeable _token1 = token1;

        // collect exit fee for users
        // do not collect exit fee for fee recipient
        uint256 exitFeeAmount;
        if (msg.sender != feeConfig.treasury) {
            // calculate exit fee
            exitFeeAmount = _fractionOfFees(_shares, feeConfig.exitFee);
            if (exitFeeAmount > 0) {
                _transfer(msg.sender, feeConfig.treasury, exitFeeAmount);
            }

            _shares -= exitFeeAmount;
        }

        _burn(msg.sender, _shares);

        uint256 positionLength = positions.length;
        uint256 amount0;
        uint256 amount1;

        // collect all swap fees first
        _collectAllSwapFee();

        withdrawnAmount0 = _fractionOfShares(_token0.balanceOf(address(this)), _shares, totalShares, false);
        withdrawnAmount1 = _fractionOfShares(_token1.balanceOf(address(this)), _shares, totalShares, false);

        uint256 i;
        for (; i < positionLength; i++) {
            Position storage position = positions[i];
            int24 tickLower = position.tickLower;
            int24 tickUpper = position.tickUpper;
            uint128 liquidity = _fractionOfShares(position.liquidity, _shares, totalShares, false).toUint128();

            (amount0, amount1) = _removeLiquidity(tickLower, tickUpper, liquidity);
            _collect(tickLower, tickUpper);
            withdrawnAmount0 += amount0;
            withdrawnAmount1 += amount1;

            position.liquidity -= liquidity;
        }

        // remove position entries with no liquidity
        i = 0;
        while(i < positions.length) {
            if (positions[i].liquidity == 0) {
                positions[i] = positions[positions.length - 1];
                positions.pop();
            }
            else {
                i++;
            }
        }

        if (withdrawnAmount0 < _amount0Min || withdrawnAmount1 < _amount1Min) revert InvalidPriceSlippage(withdrawnAmount0, withdrawnAmount1);

        _token0.safeTransfer(msg.sender, withdrawnAmount0);
        _token1.safeTransfer(msg.sender, withdrawnAmount1);

        emit WithdrawShares(msg.sender, _shares, withdrawnAmount0, withdrawnAmount1, exitFeeAmount);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function addLiquidity(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity,
        uint256 _amount0Min,
        uint256 _amount1Min,
        uint64 _deadline
    ) external override nonReentrant checkDeadline(_deadline) onlyManager returns (
        uint256 amount0,
        uint256 amount1
    ) {
        uint256 positionLength = positions.length;
        uint256 i;

        for (; i < positionLength; i++) {
            Position storage position = positions[i];
            if (position.tickLower == _tickLower && position.tickUpper == _tickUpper) {
                (amount0, amount1) = _vaultAddLiquidity(_tickLower, _tickUpper, _liquidity, _amount0Min, _amount1Min);
                position.liquidity += _liquidity;

                return (amount0, amount1);
            }
        }

        if (i == MAX_POSITION_LENGTH) revert PositionLengthExceedsLimit();

        (amount0, amount1) = _vaultAddLiquidity(_tickLower, _tickUpper, _liquidity, _amount0Min, _amount1Min);
        positions.push(Position({
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            liquidity: _liquidity
        }));
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function removeLiquidity(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity,
        uint256 _amount0Min,
        uint256 _amount1Min,
        uint64 _deadline
    ) external override nonReentrant checkDeadline(_deadline) onlyManager returns (
        uint256 amount0,
        uint256 amount1
    ) {
        uint256 positionLength = positions.length;

        for (uint256 i; i < positionLength; i++) {
            Position storage position = positions[i];
            if (position.tickLower == _tickLower && position.tickUpper == _tickUpper) {
                // collect swap fee before remove liquidity to ensure correct calculation of performance fee
                _collectPositionSwapFee(position);

                (amount0, amount1) = _removeLiquidity(_tickLower, _tickUpper, _liquidity);
                if (amount0 < _amount0Min || amount1 < _amount1Min) revert InvalidPriceSlippage(amount0, amount1);
                _collect(_tickLower, _tickUpper);

                if (position.liquidity == _liquidity) {
                    positions[i] = positions[positionLength - 1];
                    positions.pop();
                }
                else {
                    position.liquidity -= _liquidity;
                }

                return (amount0, amount1);
            }
        }

        revert PositionDoesNotExist();
    }

    function _vaultAddLiquidity(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity,
        uint256 _amount0Min,
        uint256 _amount1Min
    ) internal returns (
        uint256 amount0,
        uint256 amount1
    ) {
        (amount0, amount1) = _addLiquidity(msg.sender, _tickLower, _tickUpper, _liquidity, abi.encode(address(0)));
        if (amount0 < _amount0Min || amount1 < _amount1Min) revert InvalidPriceSlippage(amount0, amount1);
    }

    function _depositorAddLiquidity(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity
    ) internal returns (
        uint256 amount0,
        uint256 amount1
    ) {
        (amount0, amount1) = _addLiquidity(msg.sender, _tickLower, _tickUpper, _liquidity, abi.encode(msg.sender));
    }

    function _addLiquidity(
        address _sender,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity,
        bytes memory _callbackData
    ) internal checkLiquidity(_liquidity) returns (
        uint256 amount0,
        uint256 amount1
    ) {
        callbackStatus = 2;
        (amount0, amount1, ) = pool.mint(_sender, address(this), _tickLower, _tickUpper, _liquidity, _callbackData);
        callbackStatus = 1;
        
        emit AddLiquidity(address(pool), _tickLower, _tickUpper, _liquidity, amount0, amount1);
    }

    function _removeLiquidity(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity
    ) internal checkLiquidity(_liquidity) returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = pool.burn(_tickLower, _tickUpper, _liquidity);

        emit RemoveLiquidity(address(pool), _tickLower, _tickUpper, _liquidity, amount0, amount1);
    }

    function _collect(int24 _tickLower, int24 _tickUpper) internal returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = pool.collect(address(this), _tickLower, _tickUpper, type(uint128).max, type(uint128).max);

        emit Collect(address(pool), _tickLower, _tickUpper, amount0, amount1);
    }

    function algebraMintCallback(
        uint256 _amount0Owed,
        uint256 _amount1Owed,
        bytes calldata _data
    ) external {
        if (callbackStatus != 2) revert InvalidCallbackStatus();
        if (address(pool) != msg.sender) revert InvalidCallbackCaller();

        address depositor = abi.decode(_data, (address));

        if (_amount0Owed > 0) {
            depositor == address(0)?
                token0.safeTransfer(msg.sender, _amount0Owed):
                token0.safeTransferFrom(depositor, msg.sender, _amount0Owed);
        }
        if (_amount1Owed > 0) {
            depositor == address(0)?
                token1.safeTransfer(msg.sender, _amount1Owed):
                token1.safeTransferFrom(depositor, msg.sender, _amount1Owed);
        }
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function collectPositionSwapFee(
        int24 _tickLower,
        int24 _tickUpper
    ) external override nonReentrant returns (
        uint128 amount0,
        uint128 amount1
    ) {
        uint256 positionLength = positions.length;

        for (uint256 i; i < positionLength; i++) {
            Position storage position = positions[i];
            if (position.tickLower == _tickLower && position.tickUpper == _tickUpper) {
                return _collectPositionSwapFee(position);
            }
        }

        revert PositionDoesNotExist();
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function collectAllSwapFee() external override nonReentrant returns (uint128 amount0, uint128 amount1) {
        return _collectAllSwapFee();
    }

    function _collectPositionSwapFee(Position storage position) internal returns(uint128 amount0, uint128 amount1) {
        pool.burn(position.tickLower, position.tickUpper, 0);
        (amount0, amount1) =  _collect(position.tickLower, position.tickUpper);

        _collectPerformanceFee(amount0, amount1);
    }

    function _collectAllSwapFee() internal returns (uint128 amount0, uint128 amount1) {
        uint256 positionLength = positions.length;
        uint128 _amount0;
        uint128 _amount1;

        for (uint256 i; i < positionLength; i++) {
            Position storage position = positions[i];
            pool.burn(position.tickLower, position.tickUpper, 0);
            (_amount0, _amount1) = _collect(position.tickLower, position.tickUpper);
            unchecked {
                amount0 += _amount0;
                amount1 += _amount1;
            }
        }

        _collectPerformanceFee(amount0, amount1);
    }

    function _collectPerformanceFee(uint128 amount0, uint128 amount1) internal {
        uint256 performanceFeeAmount0 = _fractionOfFees(amount0, feeConfig.performanceFee);
        uint256 performanceFeeAmount1 = _fractionOfFees(amount1, feeConfig.performanceFee);

        if (performanceFeeAmount0 > 0) {
            token0.safeTransfer(feeConfig.treasury, performanceFeeAmount0);
        }
        if (performanceFeeAmount1 > 0) {
            token1.safeTransfer(feeConfig.treasury, performanceFeeAmount1);
        }

        emit CollectSwapFees(address(pool), amount0, amount1, performanceFeeAmount0, performanceFeeAmount1);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function collectManagementFee() external returns (uint256 collectedShares) {
        return _collectManagementFee();
    }

    function _collectManagementFee() internal returns (uint256 collectedShares) {
        uint256 timeDiff = block.timestamp - lastCollectManagementFee;
        if (timeDiff > 0) {
            unchecked {
                uint256 feeTimesTimediff = feeConfig.managementFee * timeDiff;
                uint256 denominator = (
                    FEE_MULTIPLIER * SECONDS_IN_A_YEAR > feeTimesTimediff?
                        FEE_MULTIPLIER * SECONDS_IN_A_YEAR - feeTimesTimediff:
                        1
                );
                collectedShares = totalSupply().mulDivRoundingUp(feeTimesTimediff, denominator);
            }

            if (collectedShares > 0) {
                _mint(feeConfig.treasury, collectedShares);
                emit ManagementFeeCollected(collectedShares);
            }

            // Charge 0 management fee and initialize lastCollectManagementFee in the first deposit
            lastCollectManagementFee = block.timestamp;
        }
    }

    function algebraSwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata _data) external {
        if (callbackStatus != 2) revert InvalidCallbackStatus();
        if (address(pool) != msg.sender) revert InvalidCallbackCaller();
        if (_amount0Delta == 0 || _amount1Delta == 0) revert SwapInZeroLiquidityRegion();

        bool zeroForOne = abi.decode(_data, (bool));
        (bool isExactInput, uint256 amountToPay) =
            _amount0Delta > 0
                ? (zeroForOne, uint256(_amount0Delta))
                : (!zeroForOne, uint256(_amount1Delta));

        if (isExactInput == zeroForOne) {
            token0.safeTransfer(msg.sender, amountToPay);
        }
        else {
            token1.safeTransfer(msg.sender, amountToPay);
        }
    }

    /// @notice Simulate in-place swap
    /// @param _zeroForOne Swap direction from token0 to token1 or not
    /// @param _amountIn Amount of input token
    /// @return amountOut Output token amount
    function simulateSwapInputSingle(bool _zeroForOne, uint256 _amountIn) internal returns (uint256 amountOut) {
        (bool success, bytes memory returndata) = address(this).delegatecall(
            abi.encodeWithSignature("simulateSwapInputSingleInternal(bool,uint256)", _zeroForOne, _amountIn));
        
        if (success) {
            // shouldn't happen, revert
            revert();
        }
        else {
            if (returndata.length == 0) {
                // no result, revert
                revert();
            }

            amountOut = abi.decode(returndata, (uint256));
        }
    }

    /// @dev Helper function for simulating in-place swap
    /// @dev This function always revert, so there's no point calling it directly
    function simulateSwapInputSingleInternal(bool _zeroForOne, uint256 _amountIn) external onlyManager {
        callbackStatus = 2;
        (bool success, bytes memory returndata) = address(pool).call(
            abi.encodeWithSignature(
                "swap(address,bool,int256,uint160,bytes)",
                address(this),
                _zeroForOne,
                _amountIn.toInt256(),
                _zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                abi.encode(_zeroForOne)
            )
        );
        callbackStatus = 1;
        
        if (success) {
            (int256 amount0, int256 amount1) = abi.decode(returndata, (int256, int256));
            uint256 amountOut = uint256(-(_zeroForOne ? amount1 : amount0));
            bytes memory data = abi.encode(amountOut);
            assembly {
                revert(add(data, 32), 32)
            }
        }
        else {
            revert();
        }
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function inPoolSwap(
        bool _zeroForOne,
        uint256 _maxPaidAmount,
        uint256 _minReceivedAmount,
        uint64 _deadline
    ) external override nonReentrant onlyManager checkDeadline(_deadline) returns (
        uint256 paidAmount,
        uint256 receivedAmount
    ) {
        callbackStatus = 2;
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            _zeroForOne,
            _maxPaidAmount.toInt256(),
            _zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(_zeroForOne)
        );
        callbackStatus = 1;

        paidAmount = uint256(_zeroForOne ? amount0 : amount1);
        receivedAmount = uint256(-(_zeroForOne ? amount1 : amount0));
        if (receivedAmount < _minReceivedAmount) revert InsufficientSwapResult(_minReceivedAmount, receivedAmount);

        (ERC20Upgradeable src, ERC20Upgradeable dst) = _zeroForOne ? (token0, token1) : (token1, token0);
        emit Swap(msg.sender, src, dst, block.timestamp, address(pool), paidAmount, receivedAmount);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function executeSwap(
        bool _zeroForOne,
        uint256 _maxPaidAmount,
        uint256 _minReceivedAmount,
        uint64 _deadline,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant onlyManager checkDeadline(_deadline) returns (
        uint256 paidAmount,
        uint256 receivedAmount
    ) {
        uint256 baselineAmount = simulateSwapInputSingle(_zeroForOne, _maxPaidAmount);

        (ERC20Upgradeable src, ERC20Upgradeable dst) = _zeroForOne ? (token0, token1) : (token1, token0);

        uint256 srcBalanceBefore = src.balanceOf(address(this));
        uint256 dstBalanceBefore = dst.balanceOf(address(this));

        ISwapRelayer _swapRelayer = swapRelayer;
        src.safeTransfer(address(_swapRelayer), _maxPaidAmount);

        _swapRelayer.swap(src, dst, _maxPaidAmount, _swapRouter, _data);
        
        uint256 srcBalanceAfter = src.balanceOf(address(this));
        uint256 dstBalanceAfter = dst.balanceOf(address(this));
        paidAmount = srcBalanceBefore - srcBalanceAfter;
        receivedAmount = dstBalanceAfter - dstBalanceBefore;

        // check if received amount not less than baseline and pre-set ammount
        if (receivedAmount < baselineAmount) revert WorseRate(baselineAmount, receivedAmount);
        if (receivedAmount < _minReceivedAmount) revert InsufficientSwapResult(_minReceivedAmount, receivedAmount);

        emit Swap(msg.sender, src, dst, block.timestamp, _swapRouter, paidAmount, receivedAmount);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function positionInfo(
        int24 _tickLower,
        int24 _tickUpper
    ) external override view returns (
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    ) {
        uint256 positionsLength = positions.length;
        for (uint256 i; i < positionsLength; i++) {
            Position storage position = positions[i];
            if (position.tickLower == _tickLower && position.tickUpper == _tickUpper) {
                return VaultUtils.positionInfo(address(this), pool, positions[i]);
            }
        }

        revert PositionDoesNotExist();
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function positionInfo(
        uint256 _index
    ) external override view returns (
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    ) {
        if (_index >= positions.length) revert PositionDoesNotExist();

        return VaultUtils.positionInfo(address(this), pool, positions[_index]);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function allPositionInfo() public view returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) {
        uint256 _amount0;
        uint256 _amount1;
        uint256 _fee0;
        uint256 _fee1;

        uint256 positionsLength = positions.length;
        for (uint256 i; i < positionsLength; i++) {
            (_amount0, _amount1, _fee0, _fee1) = VaultUtils.positionInfo(address(this), pool, positions[i]);
            amount0 += _amount0;
            amount1 += _amount1;
            fee0 += _fee0;
            fee1 += _fee1;
        }
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function vaultAllUnderlyingAssets() public view returns (uint256 amount0, uint256 amount1) {
        (uint256 _amount0, uint256 _amount1, uint256 _fee0, uint256 _fee1) = allPositionInfo();
        amount0 = _amount0 + _fee0;
        amount1 = _amount1 + _fee1;
        amount0 = amount0 + token0.balanceOf(address(this));
        amount1 = amount1 + token1.balanceOf(address(this));
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function estimatedValueInToken0() external view returns (uint256 value0) {
        (uint256 _amount0, uint256 _amount1) = vaultAllUnderlyingAssets();
        value0 = VaultUtils.estimatedValueInToken0(pool, _amount0, _amount1);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function estimatedValueInToken1() external view returns (uint256 value1) {
        (uint256 _amount0, uint256 _amount1) = vaultAllUnderlyingAssets();
        value1 = VaultUtils.estimatedValueInToken1(pool, _amount0, _amount1);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function getLiquidityForAmounts(
        int24 _tickLower,
        int24 _tickUpper,
        uint256 _amount0,
        uint256 _amount1
    ) external view returns (
        uint128 liquidity
    ) {
        return VaultUtils.getLiquidityForAmounts(pool, _tickLower, _tickUpper, _amount0, _amount1);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function getAmountsForLiquidity(
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity
    ) external view returns (
        uint256 amount0,
        uint256 amount1
    ) {
        return VaultUtils.getAmountsForLiquidity(pool, _tickLower, _tickUpper, _liquidity);
    }

    /// @inheritdoc ITeaVaultAlgebraV1Point9
    function getAllPositions() external view returns (Position[] memory results) {
        return positions;
    }

    function _fractionOfShares(
        uint256 _assetAmount,
        uint256 _shares,
        uint256 _totalShares,
        bool _isRoundingUp
    ) internal pure returns (
        uint256 amount
    ) {
        amount = _isRoundingUp ? 
            _assetAmount.mulDivRoundingUp(_shares, _totalShares):
            _assetAmount.mulDiv(_shares, _totalShares);
    }

    function _fractionOfFees(uint256 _baseAmount, uint32 _feeRate) internal view returns (uint256 fee) {
        fee = _baseAmount.mulDivRoundingUp(_feeRate, FEE_MULTIPLIER);
    }

    function _abs(int128 input) internal pure returns (uint256 output) {
        output = uint256(int256(input < 0 ? -input : input));
    }

    // sanity check functions & modifiers

    function _zeroAddressNotAllowed(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }

    function _onlyNotPaused() internal view {
        if (_isPaused()) revert EnforcedPause();
    }

    function _onlyManager() internal view {
        if (msg.sender != manager) revert CallerIsNotManager();
    }

    function _checkShares(uint256 _shares) internal pure {
        if (_shares == 0) revert ZeroShares();
    }

    function _checkLiquidity(uint256 _liquidity) internal pure {
        if (_liquidity == 0) revert ZeroLiquidity();
    }

    function _checkDeadline(uint256 _deadline) internal view {
        if (block.timestamp > _deadline) revert TransactionExpired();
    }

    modifier onlyNotPaused() {
        _onlyNotPaused();
        _;
    }

    modifier onlyManager() {
        _onlyManager();
        _;
    }

    modifier checkShares(uint256 _shares) {
        _checkShares(_shares);
        _;
    }

    modifier checkLiquidity(uint256 _liquidity) {
        _checkLiquidity(_liquidity);
        _;
    }

    modifier checkDeadline(uint256 _deadline) {
        _checkDeadline(_deadline);
        _;
    }
}