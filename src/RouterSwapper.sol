// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Swap adapter for raw 0x Swap API v2 calldata.
abstract contract RouterSwapper {
    using SafeERC20 for IERC20;

    address public immutable zeroxAllowanceHolder;

    error InvalidSwapRouter();
    error MissingSwapData();
    error SameToken();
    error SlippageError();
    error SwapFailed();
    error SwapInflowDetected();

    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    struct RouterSwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
    }

    constructor(
        address _zeroxAllowanceHolder
    ) {
        if (_zeroxAllowanceHolder == address(0)) revert InvalidSwapRouter();
        zeroxAllowanceHolder = _zeroxAllowanceHolder;
    }

    function _routerSwap(
        RouterSwapParams memory params
    ) internal returns (uint256 amountInDelta, uint256 amountOutDelta) {
        if (params.amountIn == 0) {
            if (params.amountOutMin != 0) revert SlippageError();
            return (0, 0);
        }
        if (params.swapData.length == 0) revert MissingSwapData();
        if (address(params.tokenIn) == address(params.tokenOut)) revert SameToken();

        uint256 balanceInBefore = params.tokenIn.balanceOf(address(this));
        uint256 balanceOutBefore = params.tokenOut.balanceOf(address(this));

        // 0x Swap API v2: the configured AllowanceHolder is both spender and call target.
        params.tokenIn.forceApprove(zeroxAllowanceHolder, params.amountIn);
        (bool success,) = zeroxAllowanceHolder.call(params.swapData);
        if (!success) revert SwapFailed();

        // All authorized consumption of tokenIn is allowance-mediated, so the remaining
        // allowance measures the true spend. Requiring the source balance to match it
        // exactly rejects any third-party tokenIn inflow arriving during the call.
        amountInDelta = params.amountIn - params.tokenIn.allowance(address(this), zeroxAllowanceHolder);
        params.tokenIn.forceApprove(zeroxAllowanceHolder, 0);

        uint256 balanceInAfter = params.tokenIn.balanceOf(address(this));
        uint256 balanceOutAfter = params.tokenOut.balanceOf(address(this));
        if (balanceInAfter != balanceInBefore - amountInDelta) revert SwapInflowDetected();
        if (balanceOutAfter < balanceOutBefore) revert SwapFailed();

        amountOutDelta = balanceOutAfter - balanceOutBefore;
        if (amountOutDelta < params.amountOutMin) revert SlippageError();

        emit Swap(address(params.tokenIn), address(params.tokenOut), amountInDelta, amountOutDelta);
    }
}
