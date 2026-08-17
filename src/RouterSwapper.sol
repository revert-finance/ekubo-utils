// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";

/// @notice Swap adapter compatible with the current Revert 0x and Universal Router quote payloads.
abstract contract RouterSwapper {
    using SafeERC20 for IERC20;

    address public immutable universalRouter;
    address public immutable zeroxAllowanceHolder;

    error InvalidSwapRouter();
    error MissingSwapData();
    error SameToken();
    error SlippageError();
    error SwapFailed();
    error SwapInputExceeded();

    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    struct UniversalRouterData {
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    struct RouterSwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
    }

    constructor(
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) {
        if (_universalRouter == address(0) || _zeroxAllowanceHolder == address(0)) revert InvalidSwapRouter();
        universalRouter = _universalRouter;
        zeroxAllowanceHolder = _zeroxAllowanceHolder;
    }

    /// @dev Universal Router data is abi.encode(router, abi.encode(UniversalRouterData)); 0x data is raw calldata.
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

        bool isUniversalRouter;
        bytes memory swapData = params.swapData;
        address configuredUniversalRouter = universalRouter;
        assembly ("memory-safe") {
            // abi.encode(address, bytes) stores the address right-aligned in its first word.
            isUniversalRouter := and(
                iszero(lt(mload(swapData), 32)),
                eq(mload(add(swapData, 32)), configuredUniversalRouter)
            )
        }

        if (isUniversalRouter) {
            (address target, bytes memory routerData) = abi.decode(swapData, (address, bytes));
            if (target != universalRouter) revert InvalidSwapRouter();
            UniversalRouterData memory data = abi.decode(routerData, (UniversalRouterData));
            params.tokenIn.safeTransfer(target, params.amountIn);
            IUniversalRouter(target).execute(data.commands, data.inputs, data.deadline);
        } else {
            // 0x Swap API v2: the configured AllowanceHolder is both spender and call target.
            params.tokenIn.forceApprove(zeroxAllowanceHolder, params.amountIn);
            (bool success,) = zeroxAllowanceHolder.call(swapData);
            if (!success) revert SwapFailed();
            params.tokenIn.forceApprove(zeroxAllowanceHolder, 0);
        }

        uint256 balanceInAfter = params.tokenIn.balanceOf(address(this));
        uint256 balanceOutAfter = params.tokenOut.balanceOf(address(this));
        if (balanceInAfter > balanceInBefore || balanceOutAfter < balanceOutBefore) revert SwapFailed();

        amountInDelta = balanceInBefore - balanceInAfter;
        amountOutDelta = balanceOutAfter - balanceOutBefore;
        if (amountInDelta > params.amountIn) revert SwapInputExceeded();
        if (amountOutDelta < params.amountOutMin) revert SlippageError();

        emit Swap(address(params.tokenIn), address(params.tokenOut), amountInDelta, amountOutDelta);
    }
}
