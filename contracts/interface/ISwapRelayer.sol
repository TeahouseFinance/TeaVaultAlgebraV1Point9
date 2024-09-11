// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface ISwapRelayer {

    receive() external payable;

    function swap(
        ERC20Upgradeable _srcToken,
        ERC20Upgradeable _dstToken,
        uint256 _amountIn,
        address _swapRouter,
        bytes calldata _data
    ) external;

}