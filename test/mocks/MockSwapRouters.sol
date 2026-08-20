// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockAllowanceHolder {
    using SafeERC20 for IERC20;

    function fill(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    ) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function fillWithThirdPartyInflow(
        address tokenIn,
        address tokenOut,
        address thirdParty,
        uint256 amountIn,
        uint256 thirdPartyAmount,
        uint256 amountOut
    ) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).safeTransferFrom(thirdParty, msg.sender, thirdPartyAmount);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function fillWithSideOutput(
        address tokenIn,
        address tokenOut,
        address sideToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 sideAmount
    ) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        IERC20(sideToken).safeTransfer(msg.sender, sideAmount);
    }
}
