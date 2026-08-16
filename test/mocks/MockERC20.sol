// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

contract MockFeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Fee Token", "FEE") {}

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        uint256 fee = amount / 100;
        super._transfer(from, to, amount - fee);
        if (fee != 0) _burn(from, fee);
    }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
