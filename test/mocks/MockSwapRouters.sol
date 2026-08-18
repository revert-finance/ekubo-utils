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
}

interface IMintableERC20 {
    function mint(
        address to,
        uint256 amount
    ) external;
}

contract MockUniversalRouter {
    using SafeERC20 for IERC20;

    function execute(
        bytes calldata,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable {
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp <= deadline, "expired");
        (address tokenIn, address tokenOut, address recipient, uint256 amountIn, uint256 amountOut) =
            abi.decode(inputs[0], (address, address, address, uint256, uint256));
        IERC20(tokenIn).safeTransfer(address(0xdead), amountIn);
        // Model output arriving from a pool rather than consuming pre-existing
        // router inventory.
        IMintableERC20(tokenOut).mint(recipient, amountOut);
        if (inputs.length > 1) {
            (address sweepToken, address sweepRecipient, uint256 sweepAmount) =
                abi.decode(inputs[1], (address, address, uint256));
            IERC20(sweepToken).safeTransfer(sweepRecipient, sweepAmount);
        }
    }
}
