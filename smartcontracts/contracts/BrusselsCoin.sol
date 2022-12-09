// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

import "./DemurrageCoin.sol";
import "hardhat/console.sol";

/**
 * agEUR stable coin on polygon: 0xE0B52e49357Fd4DAf2c15e02058DCE6BC0057db4
 */

contract BrusselsCoin is DemurrageCoin {
    constructor(address stableCoinAddress, address feeCollectorAddress)
        DemurrageCoin(
            "Brussels Coin",
            "BXL",
            stableCoinAddress,
            feeCollectorAddress, // address to collect the transaction and demurrage fees
            1 * (10**uint256(6 - 2)), // withdrawal fees (i.e. 1%)
            1 * (10**uint256(6 - 2)), // transaction fees (i.e. 1%)
            1 * (10**uint256(6 - 2)), // 1% demurrage rate per period // demurrage fees per period per thousand (i.e. 1%)
            42524 minutes, // demurrage period (1 moon cycle = 29.53059 days = 42,524 minutes)
            block.timestamp
        )
    {}
}
