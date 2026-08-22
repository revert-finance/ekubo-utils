// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {RouterSwapper} from "./RouterSwapper.sol";
import {EkuboPoolKey, IEkuboPositions} from "./interfaces/IEkuboPositions.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

/// @title EkuboUtils
/// @notice Stateless utility for swapping, creating, and managing canonical Ekubo concentrated-liquidity positions.
/// @dev Position NFTs are held only for the duration of an operation. Extensions and stableswap pools are unsupported.
contract EkuboUtils is RouterSwapper, IERC721Receiver {
    using SafeERC20 for IERC20;

    int32 internal constant MIN_TICK = -88_722_835;
    int32 internal constant MAX_TICK = 88_722_835;
    uint32 internal constant MAX_TICK_SPACING = 698_605;

    IEkuboPositions public immutable positions;
    address public immutable core;
    IWETH9 public immutable weth;
    IPermit2 public immutable permit2;

    uint256 private _locked = 1;

    error AmountError();
    error AmountOverflow();
    error DeadlineExpired();
    error EtherSendFailed();
    error ExtensionsNotSupported();
    error FeesMustBeCollected();
    error FullWithdrawalRequired(uint128 available, uint128 requested);
    error InvalidAddress();
    error InvalidEtherSender();
    error InvalidPool();
    error InvalidRecipient();
    error InvalidTicks();
    error NativeWrappedPairNotSupported();
    error NftOwnerOnly();
    error NotSupportedWhatToDo();
    error ReentrantCall();
    error SelfSend();
    error StableswapNotSupported();
    error TargetTokenNotInPool();
    error TooMuchEtherSent();
    error TransferError();
    error UnexpectedSwapOutput();
    error UnexpectedTokenId();
    error WrongContract();

    event CompoundFees(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event ChangeRange(uint256 indexed tokenId, uint256 indexed newTokenId);
    event SwapAndIncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event SwapAndMint(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event WithdrawAndCollect(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event WithdrawAndCollectAndSwap(uint256 indexed tokenId, address indexed token, uint256 amount);

    enum WhatToDo {
        CHANGE_RANGE,
        WITHDRAW_AND_COLLECT_AND_SWAP,
        COMPOUND_FEES
    }

    /// @notice Discriminator for data attached to an owner-initiated safeTransferFrom.
    enum NftTransferAction {
        EXECUTE,
        INCREASE_LIQUIDITY
    }

    struct PositionSpec {
        EkuboPoolKey poolKey;
        int32 tickLower;
        int32 tickUpper;
    }

    struct Instructions {
        WhatToDo whatToDo;
        PositionSpec position;
        address targetToken;
        uint128 amountRemoveMin0;
        uint128 amountRemoveMin1;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        bool collectFees;
        PositionSpec newPosition;
        uint128 liquidity;
        uint128 minLiquidity;
        uint256 deadline;
        address recipient;
        address recipientNFT;
        bool unwrap;
        bytes returnData;
        bytes newPositionReturnData;
    }

    struct SwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
        address recipient;
        bytes swapData;
        bool unwrap;
        bytes permitData;
    }

    struct SwapAndMintParams {
        PositionSpec position;
        uint256 amount0;
        uint256 amount1;
        address recipient;
        address recipientNFT;
        uint256 deadline;
        IERC20 swapSourceToken;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint128 minLiquidity;
        bytes returnData;
        bool unwrap;
        bytes permitData;
    }

    struct SwapAndIncreaseLiquidityParams {
        uint256 tokenId;
        PositionSpec position;
        uint256 amount0;
        uint256 amount1;
        address recipient;
        uint256 deadline;
        IERC20 swapSourceToken;
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        uint128 minLiquidity;
        bytes returnData;
        bool unwrap;
        bytes permitData;
    }

    struct PrepareAddState {
        uint256 needed0;
        uint256 needed1;
        uint256 neededOther;
        uint256 balanceBefore0;
        uint256 balanceBefore1;
        uint256 balanceBeforeOther;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrantCall();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        IEkuboPositions _positions,
        address _core,
        IWETH9 _weth,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2
    ) RouterSwapper(_zeroxAllowanceHolder) {
        if (
            address(_positions) == address(0) || _core == address(0) || address(_weth) == address(0)
                || address(_permit2) == address(0)
        ) revert InvalidAddress();
        positions = _positions;
        core = _core;
        weth = _weth;
        permit2 = _permit2;
    }

    /// @notice Pulls an approved NFT from its owner, executes an action, and returns the original NFT.
    function execute(
        uint256 tokenId,
        Instructions calldata instructions
    ) external nonReentrant returns (uint256 newTokenId) {
        if (positions.ownerOf(tokenId) != msg.sender) revert NftOwnerOnly();
        positions.transferFrom(msg.sender, address(this), tokenId);
        newTokenId = _executePositionAction(tokenId, instructions);
        _transferPosition(msg.sender, tokenId, instructions.returnData);
    }

    /// @notice Executes instructions sent with a safe NFT transfer initiated directly by its owner.
    /// @dev data must be abi.encode(NftTransferAction, abi.encode(actionParams)).
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external nonReentrant returns (bytes4) {
        if (msg.sender != address(positions)) revert WrongContract();
        if (from == address(this)) revert SelfSend();
        // An approved third-party operator must not be able to choose withdrawal recipients for an owner's NFT.
        if (operator != from) revert NftOwnerOnly();

        (NftTransferAction action, bytes memory actionData) = abi.decode(data, (NftTransferAction, bytes));
        bytes memory returnData;
        if (action == NftTransferAction.EXECUTE) {
            Instructions memory instructions = abi.decode(actionData, (Instructions));
            _executePositionAction(tokenId, instructions);
            returnData = instructions.returnData;
        } else if (action == NftTransferAction.INCREASE_LIQUIDITY) {
            SwapAndIncreaseLiquidityParams memory params = abi.decode(actionData, (SwapAndIncreaseLiquidityParams));
            if (params.tokenId != tokenId) revert UnexpectedTokenId();
            _swapAndIncreaseLiquidity(tokenId, from, params);
            returnData = params.returnData;
        } else {
            revert NotSupportedWhatToDo();
        }
        _transferPosition(from, tokenId, returnData);
        return IERC721Receiver.onERC721Received.selector;
    }

    function swap(
        SwapParams calldata params
    ) external payable nonReentrant returns (uint256 amountOut) {
        _checkDeadline(params.deadline);
        _validateRecipient(params.recipient);
        if (address(params.tokenIn) == address(params.tokenOut)) revert SameToken();

        _prepareAdd(
            msg.sender,
            msg.value,
            params.tokenIn,
            IERC20(address(0)),
            IERC20(address(0)),
            params.amountIn,
            0,
            0,
            params.permitData
        );

        (uint256 spent, uint256 received) = _routerSwap(
            RouterSwapParams(params.tokenIn, params.tokenOut, params.amountIn, params.minAmountOut, params.swapData)
        );
        amountOut = received;
        if (received != 0) _transferToken(params.recipient, params.tokenOut, received, params.unwrap);
        if (spent < params.amountIn) {
            _transferToken(params.recipient, params.tokenIn, params.amountIn - spent, params.unwrap);
        }
    }

    function swapAndMint(
        SwapAndMintParams calldata params
    ) external payable nonReentrant returns (uint256 tokenId, uint128 liquidity, uint128 amount0, uint128 amount1) {
        _checkDeadline(params.deadline);
        _validatePosition(params.position);
        _validateRecipient(params.recipient);
        _validateRecipient(params.recipientNFT);

        (IERC20 token0, IERC20 token1) = _normalizedTokens(params.position.poolKey);
        _prepareAdd(
            msg.sender,
            msg.value,
            token0,
            token1,
            params.swapSourceToken,
            params.amount0,
            params.amount1,
            params.amountIn0 + params.amountIn1,
            params.permitData
        );
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(params, token0, token1);
        (tokenId, liquidity, amount0, amount1) = _mintAndDeposit(params.position, total0, total1, params.minLiquidity);
        _transferPosition(params.recipientNFT, tokenId, params.returnData);
        _returnLeftovers(params.recipient, params.position.poolKey, total0, total1, amount0, amount1, params.unwrap);
        emit SwapAndMint(tokenId, liquidity, amount0, amount1);
    }

    function _swapAndIncreaseLiquidity(
        uint256 tokenId,
        address payer,
        SwapAndIncreaseLiquidityParams memory params
    ) internal returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        _checkDeadline(params.deadline);
        _validatePosition(params.position);
        _validateRecipient(params.recipient);

        (IERC20 token0, IERC20 token1) = _normalizedTokens(params.position.poolKey);
        _prepareAdd(
            payer,
            0,
            token0,
            token1,
            params.swapSourceToken,
            params.amount0,
            params.amount1,
            params.amountIn0 + params.amountIn1,
            params.permitData
        );

        SwapAndMintParams memory mintParams = SwapAndMintParams({
            position: params.position,
            amount0: params.amount0,
            amount1: params.amount1,
            recipient: params.recipient,
            recipientNFT: address(0),
            deadline: params.deadline,
            swapSourceToken: params.swapSourceToken,
            amountIn0: params.amountIn0,
            amountOut0Min: params.amountOut0Min,
            swapData0: params.swapData0,
            amountIn1: params.amountIn1,
            amountOut1Min: params.amountOut1Min,
            swapData1: params.swapData1,
            minLiquidity: params.minLiquidity,
            returnData: "",
            unwrap: params.unwrap,
            permitData: ""
        });
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(mintParams, token0, token1);
        (liquidity, amount0, amount1) = _deposit(tokenId, params.position, total0, total1, params.minLiquidity);
        _returnLeftovers(params.recipient, params.position.poolKey, total0, total1, amount0, amount1, params.unwrap);
        emit SwapAndIncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    function _executePositionAction(
        uint256 tokenId,
        Instructions memory instructions
    ) internal returns (uint256 newTokenId) {
        _checkDeadline(instructions.deadline);
        _validatePosition(instructions.position);
        _validateRecipient(instructions.recipient);

        (uint128 availableLiquidity,,,,) = positions.getPositionFeesAndLiquidity(
            tokenId, instructions.position.poolKey, instructions.position.tickLower, instructions.position.tickUpper
        );
        if (instructions.liquidity > availableLiquidity) revert AmountError();
        // A range change is deliberately a move, not an implicit position split. Keeping
        // residual liquidity on the original NFT would make ChangeRange ambiguous to
        // indexers and clients that follow the newly minted NFT.
        if (instructions.whatToDo == WhatToDo.CHANGE_RANGE && instructions.liquidity != availableLiquidity) {
            revert FullWithdrawalRequired(availableLiquidity, instructions.liquidity);
        }
        if (instructions.whatToDo == WhatToDo.CHANGE_RANGE && !instructions.collectFees) {
            revert FeesMustBeCollected();
        }

        (uint256 amount0, uint256 amount1) =
            _withdraw(tokenId, instructions.position, instructions.liquidity, instructions.collectFees);
        if (amount0 < instructions.amountRemoveMin0 || amount1 < instructions.amountRemoveMin1) {
            revert SlippageError();
        }
        if (amount0 < instructions.amountIn0 || amount1 < instructions.amountIn1) revert AmountError();

        if (instructions.whatToDo == WhatToDo.COMPOUND_FEES) {
            (uint256 total0, uint256 total1) = _rebalanceFromInstructions(instructions, amount0, amount1);
            (uint128 addedLiquidity, uint128 added0, uint128 added1) =
                _deposit(tokenId, instructions.position, total0, total1, instructions.minLiquidity);
            _returnLeftovers(
                instructions.recipient,
                instructions.position.poolKey,
                total0,
                total1,
                added0,
                added1,
                instructions.unwrap
            );
            emit CompoundFees(tokenId, addedLiquidity, added0, added1);
        } else if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {
            _validatePosition(instructions.newPosition);
            _requireSamePair(instructions.position.poolKey, instructions.newPosition.poolKey);
            _validateRecipient(instructions.recipientNFT);

            (uint256 total0, uint256 total1) = _rebalanceFromInstructions(instructions, amount0, amount1);
            uint128 addedLiquidity;
            uint128 added0;
            uint128 added1;
            (newTokenId, addedLiquidity, added0, added1) =
                _mintAndDeposit(instructions.newPosition, total0, total1, instructions.minLiquidity);
            _transferPosition(instructions.recipientNFT, newTokenId, instructions.newPositionReturnData);
            _returnLeftovers(
                instructions.recipient,
                instructions.newPosition.poolKey,
                total0,
                total1,
                added0,
                added1,
                instructions.unwrap
            );
            emit SwapAndMint(newTokenId, addedLiquidity, added0, added1);
            emit ChangeRange(tokenId, newTokenId);
        } else if (instructions.whatToDo == WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP) {
            _withdrawAndSwap(instructions, amount0, amount1, tokenId);
        } else {
            revert NotSupportedWhatToDo();
        }
    }

    function _withdrawAndSwap(
        Instructions memory instructions,
        uint256 amount0,
        uint256 amount1,
        uint256 tokenId
    ) internal {
        (IERC20 token0, IERC20 token1) = _normalizedTokens(instructions.position.poolKey);
        if (instructions.targetToken == address(0)) {
            if (amount0 != 0) _transferToken(instructions.recipient, token0, amount0, instructions.unwrap);
            if (amount1 != 0) _transferToken(instructions.recipient, token1, amount1, instructions.unwrap);
            emit WithdrawAndCollect(tokenId, amount0, amount1);
            return;
        }
        IERC20 target = IERC20(instructions.targetToken);
        uint256 targetAmount;

        targetAmount += _swapOrPassthrough(
            token0,
            target,
            amount0,
            instructions.amountOut0Min,
            instructions.swapData0,
            instructions.recipient,
            instructions.unwrap
        );
        targetAmount += _swapOrPassthrough(
            token1,
            target,
            amount1,
            instructions.amountOut1Min,
            instructions.swapData1,
            instructions.recipient,
            instructions.unwrap
        );
        if (targetAmount != 0) _transferToken(instructions.recipient, target, targetAmount, instructions.unwrap);
        emit WithdrawAndCollectAndSwap(tokenId, address(target), targetAmount);
    }

    function _swapOrPassthrough(
        IERC20 token,
        IERC20 target,
        uint256 amount,
        uint256 amountOutMin,
        bytes memory swapData,
        address recipient,
        bool unwrap
    ) internal returns (uint256 targetDelta) {
        if (address(token) == address(target)) return amount;
        (uint256 spent, uint256 received) = _routerSwap(RouterSwapParams(token, target, amount, amountOutMin, swapData));
        if (spent < amount) _transferToken(recipient, token, amount - spent, unwrap);
        return received;
    }

    function _rebalanceFromInstructions(
        Instructions memory instructions,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 total0, uint256 total1) {
        return _rebalancePositionAmounts(
            instructions.position,
            instructions.targetToken,
            amount0,
            amount1,
            instructions.amountIn0,
            instructions.amountOut0Min,
            instructions.swapData0,
            instructions.amountIn1,
            instructions.amountOut1Min,
            instructions.swapData1
        );
    }

    function _rebalancePositionAmounts(
        PositionSpec memory position,
        address targetToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountIn0,
        uint256 amountOut0Min,
        bytes memory swapData0,
        uint256 amountIn1,
        uint256 amountOut1Min,
        bytes memory swapData1
    ) internal returns (uint256 total0, uint256 total1) {
        (IERC20 token0, IERC20 token1) = _normalizedTokens(position.poolKey);
        total0 = amount0;
        total1 = amount1;

        if (targetToken == address(0)) return (total0, total1);
        if (targetToken == address(token0)) {
            (uint256 spent, uint256 received) =
                _routerSwap(RouterSwapParams(token1, token0, amountIn1, amountOut1Min, swapData1));
            total1 -= spent;
            total0 += received;
        } else if (targetToken == address(token1)) {
            (uint256 spent, uint256 received) =
                _routerSwap(RouterSwapParams(token0, token1, amountIn0, amountOut0Min, swapData0));
            total0 -= spent;
            total1 += received;
        } else {
            revert TargetTokenNotInPool();
        }
    }

    function _swapAndPrepareAmounts(
        SwapAndMintParams memory params,
        IERC20 token0,
        IERC20 token1
    ) internal returns (uint256 total0, uint256 total1) {
        if (address(params.swapSourceToken) == address(token0)) {
            if (params.amount0 < params.amountIn1) revert AmountError();
            (uint256 spent, uint256 received) =
                _routerSwap(RouterSwapParams(token0, token1, params.amountIn1, params.amountOut1Min, params.swapData1));
            total0 = params.amount0 - spent;
            total1 = params.amount1 + received;
        } else if (address(params.swapSourceToken) == address(token1)) {
            if (params.amount1 < params.amountIn0) revert AmountError();
            (uint256 spent, uint256 received) =
                _routerSwap(RouterSwapParams(token1, token0, params.amountIn0, params.amountOut0Min, params.swapData0));
            total1 = params.amount1 - spent;
            total0 = params.amount0 + received;
        } else if (address(params.swapSourceToken) != address(0)) {
            // Each leg must produce only its declared pool-token output. Since `received` is the
            // leg's measured output delta, requiring the balance to match it exactly rejects any
            // side output of the other pool token, which would otherwise be stranded here.
            uint256 token0BeforeLegs = token0.balanceOf(address(this));
            uint256 token1BeforeLegs = token1.balanceOf(address(this));
            (uint256 spent0, uint256 received0) = _routerSwap(
                RouterSwapParams(
                    params.swapSourceToken, token0, params.amountIn0, params.amountOut0Min, params.swapData0
                )
            );
            (uint256 spent1, uint256 received1) = _routerSwap(
                RouterSwapParams(
                    params.swapSourceToken, token1, params.amountIn1, params.amountOut1Min, params.swapData1
                )
            );
            if (
                token0.balanceOf(address(this)) != token0BeforeLegs + received0
                    || token1.balanceOf(address(this)) != token1BeforeLegs + received1
            ) revert UnexpectedSwapOutput();
            total0 = params.amount0 + received0;
            total1 = params.amount1 + received1;
            uint256 leftover = params.amountIn0 + params.amountIn1 - spent0 - spent1;
            if (leftover != 0) _transferToken(params.recipient, params.swapSourceToken, leftover, params.unwrap);
        } else {
            total0 = params.amount0;
            total1 = params.amount1;
        }
    }

    function _prepareAdd(
        address payer,
        uint256 nativeValue,
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther,
        bytes memory permitData
    ) internal {
        (uint256 needed0, uint256 needed1, uint256 neededOther) =
            _prepareNative(nativeValue, token0, token1, otherToken, amount0, amount1, amountOther);

        if (permitData.length == 0) {
            _pullExact(payer, token0, needed0);
            _pullExact(payer, token1, needed1);
            _pullExact(payer, otherToken, neededOther);
        } else {
            (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
                abi.decode(permitData, (ISignatureTransfer.PermitBatchTransferFrom, bytes));
            _pullPermit2Exact(payer, token0, token1, otherToken, needed0, needed1, neededOther, permit, signature);
        }
    }

    function _prepareNative(
        uint256 nativeValue,
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther
    ) internal returns (uint256 needed0, uint256 needed1, uint256 neededOther) {
        uint256 supplied0;
        uint256 supplied1;
        uint256 suppliedOther;
        if (nativeValue != 0) {
            weth.deposit{value: nativeValue}();
            if (address(token0) == address(weth)) {
                supplied0 = nativeValue;
                if (supplied0 > amount0) revert TooMuchEtherSent();
            } else if (address(token1) == address(weth)) {
                supplied1 = nativeValue;
                if (supplied1 > amount1) revert TooMuchEtherSent();
            } else if (address(otherToken) == address(weth)) {
                suppliedOther = nativeValue;
                if (suppliedOther > amountOther) revert TooMuchEtherSent();
            } else {
                revert TooMuchEtherSent();
            }
        }
        needed0 = amount0 - supplied0;
        needed1 = amount1 - supplied1;
        if (address(otherToken) != address(0) && otherToken != token0 && otherToken != token1) {
            neededOther = amountOther - suppliedOther;
        }
    }

    function _pullExact(
        address payer,
        IERC20 token,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(payer, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert TransferError();
    }

    function _pullPermit2Exact(
        address payer,
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 needed0,
        uint256 needed1,
        uint256 neededOther,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        bytes memory signature
    ) internal {
        PrepareAddState memory state;
        state.needed0 = needed0;
        state.needed1 = needed1;
        state.neededOther = neededOther;
        uint256 transferCount = (needed0 == 0 ? 0 : 1) + (needed1 == 0 ? 0 : 1) + (neededOther == 0 ? 0 : 1);
        if (permit.permitted.length != transferCount) revert TransferError();

        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](transferCount);
        uint256 i;
        if (needed0 != 0) {
            if (permit.permitted[i].token != address(token0)) revert TransferError();
            state.balanceBefore0 = token0.balanceOf(address(this));
            details[i++] = ISignatureTransfer.SignatureTransferDetails(address(this), needed0);
        }
        if (needed1 != 0) {
            if (permit.permitted[i].token != address(token1)) revert TransferError();
            state.balanceBefore1 = token1.balanceOf(address(this));
            details[i++] = ISignatureTransfer.SignatureTransferDetails(address(this), needed1);
        }
        if (neededOther != 0) {
            if (permit.permitted[i].token != address(otherToken)) revert TransferError();
            state.balanceBeforeOther = otherToken.balanceOf(address(this));
            details[i] = ISignatureTransfer.SignatureTransferDetails(address(this), neededOther);
        }

        permit2.permitTransferFrom(permit, details, payer, signature);
        if (needed0 != 0 && token0.balanceOf(address(this)) - state.balanceBefore0 != needed0) revert TransferError();
        if (needed1 != 0 && token1.balanceOf(address(this)) - state.balanceBefore1 != needed1) revert TransferError();
        if (neededOther != 0 && otherToken.balanceOf(address(this)) - state.balanceBeforeOther != neededOther) {
            revert TransferError();
        }
    }

    function _withdraw(
        uint256 tokenId,
        PositionSpec memory position,
        uint128 liquidity,
        bool withFees
    ) internal returns (uint256 amount0, uint256 amount1) {
        (IERC20 token0, IERC20 token1) = _normalizedTokens(position.poolKey);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));
        uint256 nativeBalanceBefore = address(this).balance;

        (uint128 withdrawn0, uint128 withdrawn1) = positions.withdraw(
            tokenId, position.poolKey, position.tickLower, position.tickUpper, liquidity, address(this), withFees
        );
        uint256 expectedNative = position.poolKey.token0 == address(0) ? withdrawn0 : 0;
        if (position.poolKey.token1 == address(0)) expectedNative += withdrawn1;
        _wrapNativeAmountAbove(nativeBalanceBefore, expectedNative);

        amount0 = withdrawn0;
        amount1 = withdrawn1;
        if (token0.balanceOf(address(this)) - balance0Before != amount0) revert TransferError();
        if (token1.balanceOf(address(this)) - balance1Before != amount1) revert TransferError();
    }

    function _deposit(
        uint256 tokenId,
        PositionSpec memory position,
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint128 minLiquidity
    ) internal returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        (uint128 amount0Max, uint128 amount1Max) = _toUint128Pair(maxAmount0, maxAmount1);
        uint256 nativeBalanceBefore = address(this).balance;
        uint256 nativeAmount = _approvePositionsAndUnwrap(position.poolKey, maxAmount0, maxAmount1);

        if (nativeAmount == 0) {
            (liquidity, amount0, amount1) = positions.deposit(
                tokenId, position.poolKey, position.tickLower, position.tickUpper, amount0Max, amount1Max, minLiquidity
            );
        } else {
            bytes memory depositCall = abi.encodeCall(
                IEkuboPositions.deposit,
                (
                    tokenId,
                    position.poolKey,
                    position.tickLower,
                    position.tickUpper,
                    amount0Max,
                    amount1Max,
                    minLiquidity
                )
            );
            (liquidity, amount0, amount1) =
                abi.decode(_positionsMulticall(depositCall, nativeAmount), (uint128, uint128, uint128));
            uint256 nativeUsed = position.poolKey.token0 == address(0) ? amount0 : amount1;
            _wrapNativeAmountAbove(nativeBalanceBefore, nativeAmount - nativeUsed);
        }
        _revokePositionsApprovals(position.poolKey);
    }

    function _mintAndDeposit(
        PositionSpec memory position,
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint128 minLiquidity
    ) internal returns (uint256 tokenId, uint128 liquidity, uint128 amount0, uint128 amount1) {
        (uint128 amount0Max, uint128 amount1Max) = _toUint128Pair(maxAmount0, maxAmount1);
        uint256 nativeBalanceBefore = address(this).balance;
        uint256 nativeAmount = _approvePositionsAndUnwrap(position.poolKey, maxAmount0, maxAmount1);

        if (nativeAmount == 0) {
            (tokenId, liquidity, amount0, amount1) = positions.mintAndDeposit(
                position.poolKey, position.tickLower, position.tickUpper, amount0Max, amount1Max, minLiquidity
            );
        } else {
            bytes memory mintCall = abi.encodeCall(
                IEkuboPositions.mintAndDeposit,
                (position.poolKey, position.tickLower, position.tickUpper, amount0Max, amount1Max, minLiquidity)
            );
            (tokenId, liquidity, amount0, amount1) =
                abi.decode(_positionsMulticall(mintCall, nativeAmount), (uint256, uint128, uint128, uint128));
            uint256 nativeUsed = position.poolKey.token0 == address(0) ? amount0 : amount1;
            _wrapNativeAmountAbove(nativeBalanceBefore, nativeAmount - nativeUsed);
        }
        _revokePositionsApprovals(position.poolKey);
    }

    /// @dev Bundles a native-paying deposit/mint call with the mandatory refundNativeToken sweep.
    function _positionsMulticall(
        bytes memory depositCall,
        uint256 nativeAmount
    ) internal returns (bytes memory result) {
        bytes[] memory calls = new bytes[](2);
        calls[0] = depositCall;
        calls[1] = abi.encodeCall(IEkuboPositions.refundNativeToken, ());
        bytes[] memory results = positions.multicall{value: nativeAmount}(calls);
        return results[0];
    }

    function _approvePositionsAndUnwrap(
        EkuboPoolKey memory poolKey,
        uint256 maxAmount0,
        uint256 maxAmount1
    ) internal returns (uint256 nativeAmount) {
        if (poolKey.token0 == address(0)) {
            nativeAmount = maxAmount0;
        } else if (maxAmount0 != 0) {
            IERC20(poolKey.token0).forceApprove(address(positions), maxAmount0);
        }
        if (poolKey.token1 == address(0)) {
            nativeAmount += maxAmount1;
        } else if (maxAmount1 != 0) {
            IERC20(poolKey.token1).forceApprove(address(positions), maxAmount1);
        }
        if (nativeAmount != 0) weth.withdraw(nativeAmount);
    }

    function _revokePositionsApprovals(
        EkuboPoolKey memory poolKey
    ) internal {
        if (poolKey.token0 != address(0)) IERC20(poolKey.token0).forceApprove(address(positions), 0);
        if (poolKey.token1 != address(0)) IERC20(poolKey.token1).forceApprove(address(positions), 0);
    }

    function _returnLeftovers(
        address recipient,
        EkuboPoolKey memory poolKey,
        uint256 total0,
        uint256 total1,
        uint256 added0,
        uint256 added1,
        bool unwrap
    ) internal {
        (IERC20 token0, IERC20 token1) = _normalizedTokens(poolKey);
        if (total0 > added0) _transferToken(recipient, token0, total0 - added0, unwrap);
        if (total1 > added1) _transferToken(recipient, token1, total1 - added1, unwrap);
    }

    /// @dev Ekubo Positions' safeTransferFrom always requires an ERC721Receiver
    /// response, including for EOAs. Use the plain transfer for EOAs while
    /// preserving the callback and return data for contract recipients.
    function _transferPosition(
        address recipient,
        uint256 tokenId,
        bytes memory data
    ) internal {
        if (recipient.code.length == 0) {
            positions.transferFrom(address(this), recipient, tokenId);
        } else {
            positions.safeTransferFrom(address(this), recipient, tokenId, data);
        }
    }

    function _transferToken(
        address recipient,
        IERC20 token,
        uint256 amount,
        bool unwrap
    ) internal {
        if (address(token) == address(weth) && unwrap) {
            weth.withdraw(amount);
            (bool sent,) = recipient.call{value: amount}("");
            if (!sent) revert EtherSendFailed();
        } else {
            token.safeTransfer(recipient, amount);
        }
    }

    function _normalizedTokens(
        EkuboPoolKey memory poolKey
    ) internal view returns (IERC20 token0, IERC20 token1) {
        token0 = IERC20(poolKey.token0 == address(0) ? address(weth) : poolKey.token0);
        token1 = IERC20(poolKey.token1 == address(0) ? address(weth) : poolKey.token1);
        if (token0 == token1) revert NativeWrappedPairNotSupported();
    }

    function _validatePosition(
        PositionSpec memory position
    ) internal view {
        EkuboPoolKey memory poolKey = position.poolKey;
        if (poolKey.token0 >= poolKey.token1) revert InvalidPool();

        uint256 config = uint256(poolKey.config);
        if (config >> 96 != 0) revert ExtensionsNotSupported();
        if ((config & 0x80000000) == 0) revert StableswapNotSupported();
        uint256 spacing = config & 0x7fffffff;
        // The config mask bounds this conversion well below int256.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signedSpacing = int256(spacing);
        if (
            spacing == 0 || spacing > MAX_TICK_SPACING || position.tickLower < MIN_TICK || position.tickUpper > MAX_TICK
                || position.tickLower >= position.tickUpper || int256(position.tickLower) % signedSpacing != 0
                || int256(position.tickUpper) % signedSpacing != 0
        ) revert InvalidTicks();
        _normalizedTokens(poolKey);
    }

    function _requireSamePair(
        EkuboPoolKey memory a,
        EkuboPoolKey memory b
    ) internal pure {
        if (a.token0 != b.token0 || a.token1 != b.token1) revert InvalidPool();
    }

    function _checkDeadline(
        uint256 deadline
    ) internal view {
        // A bounded timestamp is the intended transaction-expiry mechanism.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _validateRecipient(
        address recipient
    ) internal view {
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(weth)
                || recipient == zeroxAllowanceHolder
        ) revert InvalidRecipient();
    }

    function _toUint128Pair(
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128, uint128) {
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert AmountOverflow();
        // Both conversions are bounded by the check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amount0Cast = uint128(amount0);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amount1Cast = uint128(amount1);
        return (amount0Cast, amount1Cast);
    }

    function _wrapNativeAmountAbove(
        uint256 baseline,
        uint256 expectedAmount
    ) internal {
        uint256 balance = address(this).balance;
        if (balance < baseline || balance - baseline != expectedAmount) revert TransferError();
        if (expectedAmount != 0) weth.deposit{value: expectedAmount}();
    }

    receive() external payable {
        if (msg.sender != address(weth) && msg.sender != address(positions) && msg.sender != core) {
            revert InvalidEtherSender();
        }
    }
}
