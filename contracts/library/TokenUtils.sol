// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance

pragma solidity =0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library TokenUtils {
    using SafeERC20 for ERC20Upgradeable;

    error NativeTransferFailed();

    uint8 constant NATIVE_DECIMALS = 18;

    function isNative(ERC20Upgradeable _token) internal pure returns (bool) {
        return address(_token) == address(0);
    }

    function safeUniversalTransfer(ERC20Upgradeable _token, address _to, uint256 _value) internal {
        if (_value > 0) {
            isNative(_token) ? safeNativeTransfer(_to, _value) : _token.safeTransfer(_to, _value);
        }
    }

    function safeNativeTransfer(address _to, uint256 _value) internal {
        (bool success, ) = _to.call{value: _value}("");
        if (!success) revert NativeTransferFailed();
    }

    function getBalance(ERC20Upgradeable _token, address _account) internal view returns (uint256 balance) {
        return isNative(_token) ? _account.balance : _token.balanceOf(_account);
    }
}