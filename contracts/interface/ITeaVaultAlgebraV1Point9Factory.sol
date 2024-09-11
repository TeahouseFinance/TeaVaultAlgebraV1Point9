// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface ITeaVaultAlgebraV1Point9Factory {

    event VaultDeployed(address deployedAddress);

    function getBeacon() external view returns (address beaconAddress);
    function pauseAllVaults() external;
    function unpauseAllVaults() external;
    function isAllVaultsPaused() external view returns (bool isPaused);

}