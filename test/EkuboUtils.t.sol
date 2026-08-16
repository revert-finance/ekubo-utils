// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {EkuboUtils} from "../src/EkuboUtils.sol";
import {RouterSwapper} from "../src/RouterSwapper.sol";
import {EkuboPoolKey} from "../src/interfaces/IEkuboPositions.sol";
import {IEkuboPositions} from "../src/interfaces/IEkuboPositions.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {MockERC20, MockFeeOnTransferERC20, MockWETH} from "./mocks/MockERC20.sol";
import {MockCore, MockEkuboPositions} from "./mocks/MockEkubo.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockAllowanceHolder, MockUniversalRouter} from "./mocks/MockSwapRouters.sol";

contract EkuboUtilsTest is Test {
    event WithdrawAndCollect(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");

    MockERC20 internal token0;
    MockERC20 internal token1;
    MockERC20 internal tokenOut;
    MockWETH internal weth;
    MockCore internal core;
    MockEkuboPositions internal positions;
    MockPermit2 internal permit2;
    MockAllowanceHolder internal allowanceHolder;
    MockUniversalRouter internal universalRouter;
    EkuboUtils internal utils;

    EkuboUtils.PositionSpec internal spec;

    function setUp() external {
        token0 = new MockERC20("Token 0", "TK0");
        token1 = new MockERC20("Token 1", "TK1");
        tokenOut = new MockERC20("Output", "OUT");
        weth = new MockWETH();
        core = new MockCore();
        positions = new MockEkuboPositions(core);
        permit2 = new MockPermit2();
        allowanceHolder = new MockAllowanceHolder();
        universalRouter = new MockUniversalRouter();
        utils = new EkuboUtils(
            IEkuboPositions(address(positions)),
            address(core),
            IWETH9(address(weth)),
            address(universalRouter),
            address(allowanceHolder),
            IPermit2(address(permit2))
        );

        (address first, address second) =
            address(token0) < address(token1) ? (address(token0), address(token1)) : (address(token1), address(token0));
        spec = EkuboUtils.PositionSpec({
            poolKey: EkuboPoolKey(first, second, bytes32(uint256(0x80000001))), tickLower: -100, tickUpper: 100
        });

        token0.mint(owner, 1_000 ether);
        token1.mint(owner, 1_000 ether);
        tokenOut.mint(address(allowanceHolder), 1_000 ether);
        tokenOut.mint(address(universalRouter), 1_000 ether);
        token0.mint(address(positions), 1_000 ether);
        token1.mint(address(positions), 1_000 ether);
    }

    function testSwapThroughZeroXAndRevokeAllowance() external {
        vm.startPrank(owner);
        token0.approve(address(utils), 10 ether);
        bytes memory data =
            abi.encodeCall(MockAllowanceHolder.fill, (address(token0), address(tokenOut), 8 ether, 12 ether));
        uint256 amountOut = utils.swap(
            EkuboUtils.SwapParams({
                tokenIn: token0,
                tokenOut: tokenOut,
                amountIn: 10 ether,
                minAmountOut: 12 ether,
                deadline: block.timestamp,
                recipient: recipient,
                swapData: data,
                unwrap: false,
                permitData: ""
            })
        );
        vm.stopPrank();

        assertEq(amountOut, 12 ether);
        assertEq(tokenOut.balanceOf(recipient), 12 ether);
        assertEq(token0.balanceOf(recipient), 2 ether);
        assertEq(token0.allowance(address(utils), address(allowanceHolder)), 0);
        assertEq(token0.balanceOf(address(utils)), 0);
    }

    function testSwapThroughUniversalRouterPayload() external {
        vm.startPrank(owner);
        token0.approve(address(utils), 10 ether);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(token0), address(tokenOut), address(utils), 10 ether, 15 ether);
        bytes memory routerData = abi.encode(RouterSwapper.UniversalRouterData(hex"01", inputs, block.timestamp));
        uint256 amountOut = utils.swap(
            EkuboUtils.SwapParams({
                tokenIn: token0,
                tokenOut: tokenOut,
                amountIn: 10 ether,
                minAmountOut: 15 ether,
                deadline: block.timestamp,
                recipient: recipient,
                swapData: abi.encode(address(universalRouter), routerData),
                unwrap: false,
                permitData: ""
            })
        );
        vm.stopPrank();

        assertEq(amountOut, 15 ether);
        assertEq(tokenOut.balanceOf(recipient), 15 ether);
    }

    function testSwapAndMintUsesPositionsAllowanceAndRevokesIt() external {
        (IERC20 first, IERC20 second) = _tokens();
        vm.startPrank(owner);
        first.approve(address(utils), 20 ether);
        second.approve(address(utils), 10 ether);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = utils.swapAndMint(
            EkuboUtils.SwapAndMintParams({
                position: spec,
                amount0: 20 ether,
                amount1: 10 ether,
                recipient: recipient,
                recipientNFT: owner,
                deadline: block.timestamp,
                swapSourceToken: IERC20(address(0)),
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                minLiquidity: 15 ether,
                returnData: "",
                unwrap: false,
                permitData: ""
            })
        );
        vm.stopPrank();

        assertEq(positions.ownerOf(tokenId), owner);
        assertEq(liquidity, 15 ether);
        assertEq(amount0, 10 ether);
        assertEq(amount1, 5 ether);
        assertEq(first.balanceOf(recipient), 10 ether);
        assertEq(second.balanceOf(recipient), 5 ether);
        assertEq(first.allowance(address(utils), address(core)), 0);
        assertEq(second.allowance(address(utils), address(core)), 0);
        assertEq(first.allowance(address(utils), address(positions)), 0);
        assertEq(second.allowance(address(utils), address(positions)), 0);
    }

    function testOwnerCanIncreaseByDirectNftTransferWithoutNftApproval() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(0, 0, 0, 0, 0));
        (IERC20 first, IERC20 second) = _tokens();
        EkuboUtils.SwapAndIncreaseLiquidityParams memory params = EkuboUtils.SwapAndIncreaseLiquidityParams({
            tokenId: tokenId,
            position: spec,
            amount0: 8 ether,
            amount1: 4 ether,
            recipient: recipient,
            deadline: block.timestamp,
            swapSourceToken: IERC20(address(0)),
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            minLiquidity: 6 ether,
            returnData: "",
            unwrap: false,
            permitData: ""
        });

        assertEq(positions.getApproved(tokenId), address(0));
        vm.startPrank(owner);
        first.approve(address(utils), 8 ether);
        second.approve(address(utils), 4 ether);
        positions.safeTransferFrom(
            owner,
            address(utils),
            tokenId,
            abi.encode(EkuboUtils.NftTransferAction.INCREASE_LIQUIDITY, abi.encode(params))
        );
        vm.stopPrank();

        assertEq(positions.ownerOf(tokenId), owner);
        assertEq(positions.getApproved(tokenId), address(0));
        (uint128 liquidity,,,,) =
            positions.getPositionFeesAndLiquidity(tokenId, spec.poolKey, spec.tickLower, spec.tickUpper);
        assertEq(liquidity, 6 ether);
    }

    function testOwnerCanFundDirectNftIncreaseWithPermit2() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(0, 0, 0, 0, 0));
        (IERC20 first, IERC20 second) = _tokens();
        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](2);
        permitted[0] = ISignatureTransfer.TokenPermissions(address(first), 8 ether);
        permitted[1] = ISignatureTransfer.TokenPermissions(address(second), 4 ether);
        bytes memory permitData = abi.encode(
            ISignatureTransfer.PermitBatchTransferFrom(permitted, 2, block.timestamp), bytes("test-signature")
        );
        EkuboUtils.SwapAndIncreaseLiquidityParams memory params = EkuboUtils.SwapAndIncreaseLiquidityParams({
            tokenId: tokenId,
            position: spec,
            amount0: 8 ether,
            amount1: 4 ether,
            recipient: recipient,
            deadline: block.timestamp,
            swapSourceToken: IERC20(address(0)),
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            minLiquidity: 6 ether,
            returnData: "",
            unwrap: false,
            permitData: permitData
        });

        vm.startPrank(owner);
        first.approve(address(permit2), 8 ether);
        second.approve(address(permit2), 4 ether);
        positions.safeTransferFrom(
            owner,
            address(utils),
            tokenId,
            abi.encode(EkuboUtils.NftTransferAction.INCREASE_LIQUIDITY, abi.encode(params))
        );
        vm.stopPrank();

        assertEq(positions.ownerOf(tokenId), owner);
        (uint128 liquidity,,,,) =
            positions.getPositionFeesAndLiquidity(tokenId, spec.poolKey, spec.tickLower, spec.tickUpper);
        assertEq(liquidity, 6 ether);
    }

    function testOwnerCanExecuteByDirectNftTransfer() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(10, 10, 10, 2, 3));
        EkuboUtils.Instructions memory instructions = _withdrawInstructions();

        vm.prank(owner);
        positions.safeTransferFrom(
            owner, address(utils), tokenId, abi.encode(EkuboUtils.NftTransferAction.EXECUTE, abi.encode(instructions))
        );

        assertEq(positions.ownerOf(tokenId), owner);
        (IERC20 first, IERC20 second) = _tokens();
        assertEq(first.balanceOf(recipient), 12);
        assertEq(second.balanceOf(recipient), 13);
    }

    function testApprovedNftOperatorCannotExfiltrateWithSafeTransferData() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(10, 10, 10, 0, 0));
        vm.prank(owner);
        positions.approve(attacker, tokenId);

        EkuboUtils.Instructions memory instructions = _withdrawInstructions();
        instructions.recipient = attacker;
        vm.prank(attacker);
        vm.expectRevert(EkuboUtils.NftOwnerOnly.selector);
        positions.safeTransferFrom(owner, address(utils), tokenId, abi.encode(instructions));

        assertEq(positions.ownerOf(tokenId), owner);
    }

    function testExecuteRejectsApprovedOperatorAndLeavesNftWithOwner() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(10, 10, 10, 0, 0));
        vm.prank(owner);
        positions.approve(address(utils), tokenId);

        vm.prank(attacker);
        vm.expectRevert(EkuboUtils.NftOwnerOnly.selector);
        utils.execute(tokenId, _withdrawInstructions());
        assertEq(positions.ownerOf(tokenId), owner);
    }

    function testExecuteWithdrawsAndReturnsNft() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(10, 10, 10, 2, 3));
        vm.prank(owner);
        positions.approve(address(utils), tokenId);

        vm.expectEmit(true, false, false, true, address(utils));
        emit WithdrawAndCollect(tokenId, 12, 13);
        vm.prank(owner);
        utils.execute(tokenId, _withdrawInstructions());

        assertEq(positions.ownerOf(tokenId), owner);
        (IERC20 first, IERC20 second) = _tokens();
        assertEq(first.balanceOf(recipient), 12);
        assertEq(second.balanceOf(recipient), 13);
    }

    function testChangeRangeRequiresFullLiquidity() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(10, 10, 10, 2, 3));
        EkuboUtils.Instructions memory instructions = _changeRangeInstructions();
        instructions.liquidity = 9;

        vm.startPrank(owner);
        positions.approve(address(utils), tokenId);
        vm.expectRevert(abi.encodeWithSelector(EkuboUtils.FullWithdrawalRequired.selector, uint128(10), uint128(9)));
        utils.execute(tokenId, instructions);
        vm.stopPrank();

        assertEq(positions.ownerOf(tokenId), owner);
        (uint128 liquidity,,,,) =
            positions.getPositionFeesAndLiquidity(tokenId, spec.poolKey, spec.tickLower, spec.tickUpper);
        assertEq(liquidity, 10);
    }

    function testChangeRangeRequiresFeeCollection() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(10, 10, 10, 2, 3));
        EkuboUtils.Instructions memory instructions = _changeRangeInstructions();
        instructions.collectFees = false;

        vm.startPrank(owner);
        positions.approve(address(utils), tokenId);
        vm.expectRevert(EkuboUtils.FeesMustBeCollected.selector);
        utils.execute(tokenId, instructions);
        vm.stopPrank();

        assertEq(positions.ownerOf(tokenId), owner);
    }

    function testChangeRangeMovesAllLiquidityAndReturnsBothNfts() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(10, 10, 10, 2, 3));
        EkuboUtils.Instructions memory instructions = _changeRangeInstructions();

        vm.startPrank(owner);
        positions.approve(address(utils), tokenId);
        uint256 newTokenId = utils.execute(tokenId, instructions);
        vm.stopPrank();

        assertEq(positions.ownerOf(tokenId), owner);
        assertEq(positions.ownerOf(newTokenId), owner);
        (uint128 oldLiquidity,,,,) =
            positions.getPositionFeesAndLiquidity(tokenId, spec.poolKey, spec.tickLower, spec.tickUpper);
        (uint128 newLiquidity,,,,) = positions.getPositionFeesAndLiquidity(
            newTokenId,
            instructions.newPosition.poolKey,
            instructions.newPosition.tickLower,
            instructions.newPosition.tickUpper
        );
        assertEq(oldLiquidity, 0);
        assertEq(newLiquidity, 12);
    }

    function testCompoundFeesDepositsCollectedFeesAndReturnsLeftovers() external {
        uint256 tokenId = positions.mintTo(owner, MockEkuboPositions.Position(10, 10, 10, 2, 4));
        EkuboUtils.Instructions memory instructions = _withdrawInstructions();
        instructions.whatToDo = EkuboUtils.WhatToDo.COMPOUND_FEES;
        instructions.liquidity = 0;
        instructions.minLiquidity = 3;

        vm.startPrank(owner);
        positions.approve(address(utils), tokenId);
        utils.execute(tokenId, instructions);
        vm.stopPrank();

        (uint128 liquidity,,, uint128 fees0, uint128 fees1) =
            positions.getPositionFeesAndLiquidity(tokenId, spec.poolKey, spec.tickLower, spec.tickUpper);
        assertEq(positions.ownerOf(tokenId), owner);
        assertEq(liquidity, 13);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        (IERC20 first, IERC20 second) = _tokens();
        assertEq(first.balanceOf(recipient), 1);
        assertEq(second.balanceOf(recipient), 2);
    }

    function testPermit2RejectsPoolTokensInTheWrongOrder() external {
        (IERC20 first, IERC20 second) = _tokens();
        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](2);
        permitted[0] = ISignatureTransfer.TokenPermissions(address(second), 8 ether);
        permitted[1] = ISignatureTransfer.TokenPermissions(address(first), 4 ether);
        bytes memory permitData = abi.encode(
            ISignatureTransfer.PermitBatchTransferFrom(permitted, 77, block.timestamp), bytes("test-signature")
        );
        EkuboUtils.SwapAndMintParams memory params = _emptyMintParams();
        params.amount0 = 8 ether;
        params.amount1 = 4 ether;
        params.permitData = permitData;

        vm.prank(owner);
        vm.expectRevert(EkuboUtils.TransferError.selector);
        utils.swapAndMint(params);
    }

    function testSwapWithPermit2UsesExactSignedTransfer() external {
        token0.mint(address(permit2), 0);
        vm.prank(owner);
        token0.approve(address(permit2), 10 ether);

        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](1);
        permitted[0] = ISignatureTransfer.TokenPermissions(address(token0), 10 ether);
        bytes memory permitData = abi.encode(
            ISignatureTransfer.PermitBatchTransferFrom(permitted, 1, block.timestamp), bytes("test-signature")
        );
        bytes memory data =
            abi.encodeCall(MockAllowanceHolder.fill, (address(token0), address(tokenOut), 10 ether, 10 ether));

        vm.prank(owner);
        utils.swap(
            EkuboUtils.SwapParams({
                tokenIn: token0,
                tokenOut: tokenOut,
                amountIn: 10 ether,
                minAmountOut: 10 ether,
                deadline: block.timestamp,
                recipient: recipient,
                swapData: data,
                unwrap: false,
                permitData: permitData
            })
        );
        assertEq(tokenOut.balanceOf(recipient), 10 ether);
    }

    function testRejectsExtensionAndInvalidSpacing() external {
        EkuboUtils.SwapAndMintParams memory params = _emptyMintParams();
        params.position.poolKey.config = bytes32(uint256(uint160(address(1))) << 96 | uint256(0x80000001));
        vm.prank(owner);
        vm.expectRevert(EkuboUtils.ExtensionsNotSupported.selector);
        utils.swapAndMint(params);

        params.position = spec;
        params.position.poolKey.config = bytes32(uint256(0x80000000) | uint256(698_606));
        vm.prank(owner);
        vm.expectRevert(EkuboUtils.InvalidTicks.selector);
        utils.swapAndMint(params);
    }

    function testDeadlineIsEnforced() external {
        vm.warp(100);
        EkuboUtils.SwapAndMintParams memory params = _emptyMintParams();
        params.deadline = 99;
        vm.prank(owner);
        vm.expectRevert(EkuboUtils.DeadlineExpired.selector);
        utils.swapAndMint(params);
    }

    function testFeeOnTransferFundingIsRejected() external {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20();
        feeToken.mint(owner, 100 ether);
        vm.startPrank(owner);
        feeToken.approve(address(utils), 100 ether);
        vm.expectRevert(EkuboUtils.TransferError.selector);
        utils.swap(
            EkuboUtils.SwapParams({
                tokenIn: feeToken,
                tokenOut: tokenOut,
                amountIn: 100 ether,
                minAmountOut: 0,
                deadline: block.timestamp,
                recipient: recipient,
                swapData: hex"01",
                unwrap: false,
                permitData: ""
            })
        );
        vm.stopPrank();
    }

    function testNativePoolMintWrapsOnlyRefundedLeftover() external {
        EkuboUtils.PositionSpec memory nativeSpec = EkuboUtils.PositionSpec({
            poolKey: EkuboPoolKey(address(0), address(token1), bytes32(uint256(0x80000001))),
            tickLower: -100,
            tickUpper: 100
        });
        vm.deal(owner, 20 ether);
        uint256 recipientBefore = recipient.balance;
        vm.startPrank(owner);
        token1.approve(address(utils), 10 ether);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = utils.swapAndMint{value: 20 ether}(
            EkuboUtils.SwapAndMintParams({
                position: nativeSpec,
                amount0: 20 ether,
                amount1: 10 ether,
                recipient: recipient,
                recipientNFT: owner,
                deadline: block.timestamp,
                swapSourceToken: IERC20(address(0)),
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                minLiquidity: 15 ether,
                returnData: "",
                unwrap: true,
                permitData: ""
            })
        );
        vm.stopPrank();

        assertEq(positions.ownerOf(tokenId), owner);
        assertEq(liquidity, 15 ether);
        assertEq(amount0, 10 ether);
        assertEq(amount1, 5 ether);
        assertEq(recipient.balance - recipientBefore, 10 ether);
        assertEq(token1.balanceOf(recipient), 5 ether);
        assertEq(address(core).balance, 10 ether);
        assertEq(token1.allowance(address(utils), address(positions)), 0);
        assertEq(address(utils).balance, 0);
        assertEq(weth.balanceOf(address(utils)), 0);
    }

    function testFuzzMintReturnsExactUnusedAmounts(
        uint96 amount0,
        uint96 amount1
    ) external {
        amount0 = uint96(bound(amount0, 2, 1e28));
        amount1 = uint96(bound(amount1, 2, 1e28));
        (IERC20 first, IERC20 second) = _tokens();
        MockERC20(address(first)).mint(owner, amount0);
        MockERC20(address(second)).mint(owner, amount1);

        vm.startPrank(owner);
        first.approve(address(utils), amount0);
        second.approve(address(utils), amount1);
        (uint256 tokenId,, uint256 added0, uint256 added1) = utils.swapAndMint(
            EkuboUtils.SwapAndMintParams({
                position: spec,
                amount0: amount0,
                amount1: amount1,
                recipient: recipient,
                recipientNFT: owner,
                deadline: block.timestamp,
                swapSourceToken: IERC20(address(0)),
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                minLiquidity: 0,
                returnData: "",
                unwrap: false,
                permitData: ""
            })
        );
        vm.stopPrank();

        assertEq(positions.ownerOf(tokenId), owner);
        assertEq(added0, amount0 / 2);
        assertEq(added1, amount1 / 2);
        assertEq(first.allowance(address(utils), address(positions)), 0);
        assertEq(second.allowance(address(utils), address(positions)), 0);
        assertEq(first.balanceOf(address(utils)), 0);
        assertEq(second.balanceOf(address(utils)), 0);
    }

    function _tokens() internal view returns (IERC20 first, IERC20 second) {
        return spec.poolKey.token0 == address(token0)
            ? (IERC20(address(token0)), IERC20(address(token1)))
            : (IERC20(address(token1)), IERC20(address(token0)));
    }

    function _withdrawInstructions() internal view returns (EkuboUtils.Instructions memory instructions) {
        instructions.whatToDo = EkuboUtils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        instructions.position = spec;
        // address(0) means return both pool assets without swapping, matching V3Utils.
        instructions.targetToken = address(0);
        instructions.liquidity = 10;
        instructions.collectFees = true;
        instructions.deadline = block.timestamp;
        instructions.recipient = recipient;
        instructions.recipientNFT = owner;
    }

    function _changeRangeInstructions() internal view returns (EkuboUtils.Instructions memory instructions) {
        instructions = _withdrawInstructions();
        instructions.whatToDo = EkuboUtils.WhatToDo.CHANGE_RANGE;
        instructions.newPosition = EkuboUtils.PositionSpec({poolKey: spec.poolKey, tickLower: -200, tickUpper: 200});
        instructions.minLiquidity = 1;
    }

    function _emptyMintParams() internal view returns (EkuboUtils.SwapAndMintParams memory params) {
        params.position = spec;
        params.recipient = recipient;
        params.recipientNFT = owner;
        params.deadline = block.timestamp;
    }
}
