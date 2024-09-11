
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IAlgebraPool} from "./IAlgebraPool.sol";

interface IAlgebraPoolFactory {

    function poolByPair(ERC20Upgradeable _srcToken, ERC20Upgradeable _dstToken) external returns (IAlgebraPool pool);

}