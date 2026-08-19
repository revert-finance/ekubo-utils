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

    error InvalidSwapCommand();
    error InvalidSwapRouter();
    error MissingSwapData();
    error SameToken();
    error SlippageError();
    error SwapFailed();
    error SwapInflowDetected();
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

        uint256 routerBalanceInBefore;
        if (isUniversalRouter) {
            (address target, bytes memory routerData) = abi.decode(swapData, (address, bytes));
            if (target != universalRouter) revert InvalidSwapRouter();
            UniversalRouterData memory data = abi.decode(routerData, (UniversalRouterData));
            // Only swap and cleanup commands may be forwarded to the shared router: position-manager,
            // permit, payment, and sub-plan commands could spend authority or balances outside this
            // operation. The allow-revert flag is masked out; the command type is what is restricted.
            // The bitmap allows V3/V2 exact-in/out swaps (0x00/0x01/0x08/0x09), SWEEP (0x04), V4_SWAP (0x10).
            for (uint256 i; i < data.commands.length; ++i) {
                if ((uint256(0x10313) >> (uint8(data.commands[i]) & 0x3f)) & 1 == 0) revert InvalidSwapCommand();
            }
            // Snapshot what the router already holds: the command sequence must only spend
            // input funded by this call (amounts swept back here are credited below).
            routerBalanceInBefore = params.tokenIn.balanceOf(target);
            params.tokenIn.safeTransfer(target, params.amountIn);
            IUniversalRouter(target).execute(data.commands, data.inputs, data.deadline);
        } else {
            // 0x Swap API v2: the configured AllowanceHolder is both spender and call target.
            params.tokenIn.forceApprove(zeroxAllowanceHolder, params.amountIn);
            (bool success,) = zeroxAllowanceHolder.call(swapData);
            if (!success) revert SwapFailed();
            // All authorized consumption of tokenIn is allowance-mediated, so the remaining
            // allowance measures the true spend. Requiring the source balance to match it
            // exactly rejects any third-party tokenIn inflow arriving during the call.
            uint256 allowanceSpent = params.amountIn - params.tokenIn.allowance(address(this), zeroxAllowanceHolder);
            params.tokenIn.forceApprove(zeroxAllowanceHolder, 0);
            if (params.tokenIn.balanceOf(address(this)) != balanceInBefore - allowanceSpent) {
                revert SwapInflowDetected();
            }
        }

        uint256 balanceInAfter = params.tokenIn.balanceOf(address(this));
        uint256 balanceOutAfter = params.tokenOut.balanceOf(address(this));
        if (balanceInAfter > balanceInBefore || balanceOutAfter < balanceOutBefore) revert SwapFailed();

        if (isUniversalRouter) {
            // The shared router's tokenIn balance must be unchanged by this operation, net of
            // sweep-backs to this contract: it may neither retain funded input (stranding it for
            // a later permissionless sweep) nor contribute balances it already held.
            uint256 routerBalanceInAfter = params.tokenIn.balanceOf(universalRouter);
            uint256 sweptBack = balanceInAfter + params.amountIn - balanceInBefore;
            if (
                routerBalanceInAfter > routerBalanceInBefore || routerBalanceInAfter + sweptBack < routerBalanceInBefore
            ) revert SwapInputExceeded();
        }

        amountInDelta = balanceInBefore - balanceInAfter;
        amountOutDelta = balanceOutAfter - balanceOutBefore;
        if (amountInDelta > params.amountIn) revert SwapInputExceeded();
        if (amountOutDelta < params.amountOutMin) revert SlippageError();

        emit Swap(address(params.tokenIn), address(params.tokenOut), amountInDelta, amountOutDelta);
    }
}
