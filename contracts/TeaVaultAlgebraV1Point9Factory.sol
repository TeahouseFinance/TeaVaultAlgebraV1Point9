// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {ITeaVaultAlgebraV1Point9Factory} from "./interface/ITeaVaultAlgebraV1Point9Factory.sol";
import {TeaVaultAlgebraV1Point9} from "./TeaVaultAlgebraV1Point9.sol";
import {SwapRelayer} from "./SwapRelayer.sol";

contract TeaVaultAlgebraV1Point9Factory is ITeaVaultAlgebraV1Point9Factory, Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    address private vaultBeacon;
    SwapRelayer public swapRelayer;
    address public poolFactory;

    uint256[47] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function initialize(
        address _owner,
        address _beacon,
        address _poolFactory
    ) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(_owner);
        __Pausable_init();

        vaultBeacon = _beacon;
        swapRelayer = new SwapRelayer(_owner);
        poolFactory = _poolFactory;
    }

    function createVault(
        address _owner,
        string calldata _name,
        string calldata _symbol,
        uint8 _decimalOffset,
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        address _manager,
        uint24 _feeCap,
        TeaVaultAlgebraV1Point9.FeeConfig calldata _feeConfig
    ) external onlyOwner returns (
        address deployedAddress
    ) {
        deployedAddress = address(new BeaconProxy(
            vaultBeacon,
            abi.encodeWithSelector(
                TeaVaultAlgebraV1Point9.initialize.selector,
                _owner,
                _name,
                _symbol,
                _decimalOffset,
                swapRelayer,
                poolFactory,
                _token0,
                _token1,
                _manager,
                _feeCap,
                _feeConfig
            )
        ));

        emit VaultDeployed(deployedAddress);
    }

    function getBeacon() external override view returns (address beaconAddress) {
        beaconAddress = vaultBeacon;
    }

    function pauseAllVaults() external override onlyOwner {
        _pause();
    }

    function unpauseAllVaults() external override onlyOwner {
        _unpause();
    }

    function isAllVaultsPaused() external override view returns (bool isPaused) {
        isPaused = paused();
    }
}