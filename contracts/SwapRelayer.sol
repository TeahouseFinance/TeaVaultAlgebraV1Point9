// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRelayer} from "./interface/ISwapRelayer.sol";

/// @notice SwapRelayer is a helper contract for sending calls to arbitray swap router
/// @notice Since there's no need to approve tokens to SwapRelayer, it's safe for Swapper
/// @notice to call arbitrary contracts.
contract SwapRelayer is ISwapRelayer, Ownable {
    using SafeERC20 for ERC20Upgradeable;

    mapping(address => bool) public routerWhitelist;

    receive() external payable {}

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setWhitelist(address[] calldata _router, bool[] calldata _isWhitelisted) external override onlyOwner {
        if (_router.length != _isWhitelisted.length) revert LengthMismatch();

        for (uint256 i; i < _router.length; i = i + 1) {
            routerWhitelist[_router[i]] = _isWhitelisted[i];
        }

        emit SetWhitelist(msg.sender, _router, _isWhitelisted);
    }

    function swap(
        ERC20Upgradeable _src,
        ERC20Upgradeable _dst,
        uint256 _amountIn,
        address _swapRouter,
        bytes calldata _data
    ) external override {
        if (!routerWhitelist[_swapRouter]) revert NotWhitelisted();

        _src.approve(_swapRouter, _amountIn);
        (bool success, bytes memory returndata) = _swapRouter.call(_data);
        uint256 length = returndata.length;
        if (!success) {
            // call failed, propagate revert data
            assembly ("memory-safe") {
                revert(add(returndata, 32), length)
            }
        }

        _src.approve(_swapRouter, 0);
 
         // send tokens back to caller
        _src.safeTransfer(msg.sender, _src.balanceOf(address(this)));
        _dst.safeTransfer(msg.sender, _dst.balanceOf(address(this)));
    }
}
