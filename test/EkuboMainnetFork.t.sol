// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {EkuboUtils} from "../src/EkuboUtils.sol";
import {EkuboPoolKey, IEkuboPositions} from "../src/interfaces/IEkuboPositions.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @notice Smoke tests against Ekubo v3.2.0 on Ethereum mainnet.
contract EkuboMainnetForkTest is Test {
    IEkuboPositions internal constant POSITIONS = IEkuboPositions(0x02D9876A21AF7545f8632C3af76eC90b5ad4b66D);
    address internal constant CORE = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    EkuboUtils internal constant DEPLOYED_UTILS = EkuboUtils(payable(0x4Cf798c93280E2103Ae1186B4D4AB7E9CE93df9f));
    bytes32 internal constant DEPLOYED_UTILS_RUNTIME_HASH =
        0xd5a7a45ad7f624e63c5c92dc7391ffc2d1643513e8b559b1dee86ca02025c98e;
    uint256 internal constant TOKEN_ID = 115405844744126724027399150793600264461049412098266383761154101033925042376216;

    struct ZeroXQuote {
        uint256 amountIn;
        uint256 amountOutMin;
        bytes data;
    }

    function testMainnetPositionAbiAndPoolConfig() external {
        string memory rpcUrl = _mainnetRpcUrl();
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);

        assertGt(address(POSITIONS).code.length, 0);
        assertGt(CORE.code.length, 0);
        assertTrue(POSITIONS.ownerOf(TOKEN_ID) != address(0));
        // This historical NFT may be emptied after the test is published. A successful
        // decode still verifies the live Positions ABI and the canonical pool-key shape.
        POSITIONS.getPositionFeesAndLiquidity(TOKEN_ID, _poolKey(), 0, 450);
    }

    function testMainnetDepositUsesPositionsAllowanceAndReturnsNft() external {
        string memory rpcUrl = _mainnetRpcUrl();
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);

        address owner = POSITIONS.ownerOf(TOKEN_ID);
        EkuboUtils utils = new EkuboUtils(POSITIONS, CORE, IWETH9(WETH), address(1), IPermit2(address(2)));
        EkuboUtils.PositionSpec memory position =
            EkuboUtils.PositionSpec({poolKey: _poolKey(), tickLower: 0, tickUpper: 450});
        (uint128 liquidityBefore,,,,) =
            POSITIONS.getPositionFeesAndLiquidity(TOKEN_ID, position.poolKey, position.tickLower, position.tickUpper);

        deal(WBTC, owner, 1_000_000);
        deal(CBBTC, owner, 1_000_000);
        vm.startPrank(owner);
        IERC20(WBTC).approve(address(utils), 1_000_000);
        IERC20(CBBTC).approve(address(utils), 1_000_000);
        EkuboUtils.SwapAndIncreaseLiquidityParams memory params = EkuboUtils.SwapAndIncreaseLiquidityParams({
            tokenId: TOKEN_ID,
            position: position,
            amount0: 1_000_000,
            amount1: 1_000_000,
            recipient: owner,
            deadline: block.timestamp,
            swapSourceToken: IERC20(address(0)),
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            minLiquidity: 1,
            returnData: "",
            unwrap: false,
            permitData: ""
        });
        POSITIONS.safeTransferFrom(
            owner,
            address(utils),
            TOKEN_ID,
            abi.encode(EkuboUtils.NftTransferAction.INCREASE_LIQUIDITY, abi.encode(params))
        );
        vm.stopPrank();

        (uint128 liquidityAfter,,,,) =
            POSITIONS.getPositionFeesAndLiquidity(TOKEN_ID, position.poolKey, position.tickLower, position.tickUpper);
        assertEq(POSITIONS.ownerOf(TOKEN_ID), owner);
        assertGt(liquidityAfter, liquidityBefore);
        assertEq(IERC20(WBTC).allowance(address(utils), address(POSITIONS)), 0);
        assertEq(IERC20(CBBTC).allowance(address(utils), address(POSITIONS)), 0);
        assertEq(IERC20(WBTC).allowance(address(utils), CORE), 0);
        assertEq(IERC20(CBBTC).allowance(address(utils), CORE), 0);
    }

    function testMainnetSwapAndMintWithRealPermit2Signature() external {
        string memory rpcUrl = _mainnetRpcUrl();
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);

        EkuboUtils utils = _deployUtils();
        uint256 privateKey = 0xA11CE;
        address owner = vm.addr(privateKey);
        uint256 amount0 = 1_000_000;
        uint256 amount1 = 1_000_000;
        deal(WBTC, owner, amount0);
        deal(CBBTC, owner, amount1);

        vm.startPrank(owner);
        IERC20(WBTC).approve(PERMIT2, amount0);
        IERC20(CBBTC).approve(PERMIT2, amount1);
        vm.stopPrank();

        ISignatureTransfer.TokenPermissions[] memory permissions = new ISignatureTransfer.TokenPermissions[](2);
        permissions[0] = ISignatureTransfer.TokenPermissions(WBTC, amount0);
        permissions[1] = ISignatureTransfer.TokenPermissions(CBBTC, amount1);
        ISignatureTransfer.PermitBatchTransferFrom memory permit =
            ISignatureTransfer.PermitBatchTransferFrom({permitted: permissions, nonce: 55, deadline: block.timestamp});
        bytes memory permitData = abi.encode(permit, _signPermit2Batch(permit, privateKey, address(utils)));
        EkuboUtils.PositionSpec memory position =
            EkuboUtils.PositionSpec({poolKey: _poolKey(), tickLower: 0, tickUpper: 450});

        vm.prank(owner);
        (uint256 tokenId, uint128 liquidity,,) = utils.swapAndMint(
            EkuboUtils.SwapAndMintParams({
                position: position,
                amount0: amount0,
                amount1: amount1,
                recipient: owner,
                recipientNFT: owner,
                deadline: block.timestamp,
                swapSourceToken: IERC20(address(0)),
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                minLiquidity: 1,
                returnData: "",
                unwrap: false,
                permitData: permitData
            })
        );

        assertEq(POSITIONS.ownerOf(tokenId), owner);
        assertGt(liquidity, 0);
        assertEq(IERC20(WBTC).balanceOf(address(utils)), 0);
        assertEq(IERC20(CBBTC).balanceOf(address(utils)), 0);
    }

    /// @notice Runs a complete position lifecycle against the verified production runtime.
    /// @dev Requires MAINNET_RPC_URL and --ffi because every swap leg uses a fresh firm quote
    ///      from the same Revert 0x proxy used by the SPA. No contract is deployed or mocked.
    function testMainnetDeployedUtilsThirdTokenLifecycle() external {
        string memory rpcUrl = _mainnetRpcUrl();
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);

        assertEq(address(DEPLOYED_UTILS).code.length, 23_397);
        assertEq(keccak256(address(DEPLOYED_UTILS).code), DEPLOYED_UTILS_RUNTIME_HASH);

        address owner = vm.addr(0xA11CE);
        EkuboUtils.PositionSpec memory original =
            EkuboUtils.PositionSpec({poolKey: _poolKey(), tickLower: -10_050, tickUpper: 10_050});
        uint256 amount0 = 1_000_000;
        uint256 amount1 = 1_000_000;
        deal(WBTC, owner, amount0);
        deal(CBBTC, owner, amount1);

        vm.startPrank(owner);
        IERC20(WBTC).approve(address(DEPLOYED_UTILS), amount0);
        IERC20(CBBTC).approve(address(DEPLOYED_UTILS), amount1);
        (uint256 tokenId, uint128 createdLiquidity,,) = DEPLOYED_UTILS.swapAndMint(
            EkuboUtils.SwapAndMintParams({
                position: original,
                amount0: amount0,
                amount1: amount1,
                recipient: owner,
                recipientNFT: owner,
                deadline: block.timestamp,
                swapSourceToken: IERC20(address(0)),
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                minLiquidity: 1,
                returnData: "",
                unwrap: false,
                permitData: ""
            })
        );
        vm.stopPrank();

        assertGt(createdLiquidity, 0, "create must add liquidity");
        assertEq(POSITIONS.ownerOf(tokenId), owner, "create must return the NFT");

        uint256 wethPerLeg = 0.005 ether;
        ZeroXQuote memory increase0 = _quote(WETH, WBTC, wethPerLeg, "swap-mint");
        ZeroXQuote memory increase1 = _quote(WETH, CBBTC, wethPerLeg, "swap-mint");
        deal(WETH, owner, wethPerLeg * 2);
        vm.startPrank(owner);
        IERC20(WETH).approve(address(DEPLOYED_UTILS), wethPerLeg * 2);
        POSITIONS.safeTransferFrom(
            owner,
            address(DEPLOYED_UTILS),
            tokenId,
            abi.encode(
                EkuboUtils.NftTransferAction.INCREASE_LIQUIDITY,
                abi.encode(
                    EkuboUtils.SwapAndIncreaseLiquidityParams({
                        tokenId: tokenId,
                        position: original,
                        amount0: 0,
                        amount1: 0,
                        recipient: owner,
                        deadline: block.timestamp,
                        swapSourceToken: IERC20(WETH),
                        amountIn0: increase0.amountIn,
                        amountOut0Min: increase0.amountOutMin,
                        swapData0: increase0.data,
                        amountIn1: increase1.amountIn,
                        amountOut1Min: increase1.amountOutMin,
                        swapData1: increase1.data,
                        minLiquidity: 1,
                        returnData: "",
                        unwrap: false,
                        permitData: ""
                    })
                )
            )
        );
        vm.stopPrank();

        (uint128 liquidityAfterIncrease, uint128 principal0, uint128 principal1,,) =
            POSITIONS.getPositionFeesAndLiquidity(tokenId, original.poolKey, original.tickLower, original.tickUpper);
        assertGt(liquidityAfterIncrease, createdLiquidity, "third-token increase must add liquidity");
        assertEq(POSITIONS.ownerOf(tokenId), owner, "increase must return the NFT");
        assertEq(IERC20(WETH).balanceOf(owner), 0, "both WETH input legs must execute");
        assertEq(IERC20(WETH).allowance(address(DEPLOYED_UTILS), ZEROX_ALLOWANCE_HOLDER), 0);

        uint128 liquidityToWithdraw = liquidityAfterIncrease / 4;
        // Quote half of the conservative pro-rata principal. EkuboUtils returns any unswapped
        // pool-token remainder, while the WETH delta proves both third-output swap legs executed.
        uint256 sell0 = uint256(principal0) * liquidityToWithdraw / liquidityAfterIncrease / 2;
        uint256 sell1 = uint256(principal1) * liquidityToWithdraw / liquidityAfterIncrease / 2;
        assertGt(sell0, 0);
        assertGt(sell1, 0);
        ZeroXQuote memory withdraw0 = _quote(WBTC, WETH, sell0, "withdraw-swap");
        ZeroXQuote memory withdraw1 = _quote(CBBTC, WETH, sell1, "withdraw-swap");
        uint256 wethBeforeWithdraw = IERC20(WETH).balanceOf(owner);

        EkuboUtils.Instructions memory withdraw;
        withdraw.whatToDo = EkuboUtils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        withdraw.position = original;
        withdraw.targetToken = WETH;
        withdraw.amountIn0 = withdraw0.amountIn;
        withdraw.amountOut0Min = withdraw0.amountOutMin;
        withdraw.swapData0 = withdraw0.data;
        withdraw.amountIn1 = withdraw1.amountIn;
        withdraw.amountOut1Min = withdraw1.amountOutMin;
        withdraw.swapData1 = withdraw1.data;
        withdraw.collectFees = false;
        withdraw.liquidity = liquidityToWithdraw;
        withdraw.deadline = block.timestamp;
        withdraw.recipient = owner;
        withdraw.recipientNFT = owner;

        vm.prank(owner);
        POSITIONS.safeTransferFrom(
            owner,
            address(DEPLOYED_UTILS),
            tokenId,
            abi.encode(EkuboUtils.NftTransferAction.EXECUTE, abi.encode(withdraw))
        );

        (uint128 liquidityAfterWithdraw,,,,) =
            POSITIONS.getPositionFeesAndLiquidity(tokenId, original.poolKey, original.tickLower, original.tickUpper);
        assertEq(liquidityAfterWithdraw, liquidityAfterIncrease - liquidityToWithdraw);
        assertGt(IERC20(WETH).balanceOf(owner), wethBeforeWithdraw, "withdraw must pay the third output token");
        assertEq(POSITIONS.ownerOf(tokenId), owner, "withdraw must return the NFT");

        EkuboUtils.PositionSpec memory moved =
            EkuboUtils.PositionSpec({poolKey: _poolKey(), tickLower: -9900, tickUpper: 9900});
        EkuboUtils.Instructions memory move;
        move.whatToDo = EkuboUtils.WhatToDo.CHANGE_RANGE;
        move.position = original;
        move.newPosition = moved;
        move.collectFees = true;
        move.liquidity = liquidityAfterWithdraw;
        move.minLiquidity = 1;
        move.deadline = block.timestamp;
        move.recipient = owner;
        move.recipientNFT = owner;

        vm.recordLogs();
        vm.prank(owner);
        POSITIONS.safeTransferFrom(
            owner, address(DEPLOYED_UTILS), tokenId, abi.encode(EkuboUtils.NftTransferAction.EXECUTE, abi.encode(move))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 newTokenId = _changedTokenId(logs, tokenId);
        assertTrue(newTokenId != tokenId, "move must mint a distinct NFT");

        (uint128 oldLiquidity,,,,) =
            POSITIONS.getPositionFeesAndLiquidity(tokenId, original.poolKey, original.tickLower, original.tickUpper);
        (uint128 movedLiquidity,,,,) =
            POSITIONS.getPositionFeesAndLiquidity(newTokenId, moved.poolKey, moved.tickLower, moved.tickUpper);
        assertEq(oldLiquidity, 0, "move must remove the full old range");
        assertGt(movedLiquidity, 0, "move must fund the new range");
        assertEq(POSITIONS.ownerOf(tokenId), owner, "move must return the old NFT");
        assertEq(POSITIONS.ownerOf(newTokenId), owner, "move must return the new NFT");
        assertEq(IERC20(WBTC).balanceOf(address(DEPLOYED_UTILS)), 0);
        assertEq(IERC20(CBBTC).balanceOf(address(DEPLOYED_UTILS)), 0);
        assertEq(IERC20(WETH).balanceOf(address(DEPLOYED_UTILS)), 0);
        assertEq(IERC20(WBTC).allowance(address(DEPLOYED_UTILS), ZEROX_ALLOWANCE_HOLDER), 0);
        assertEq(IERC20(CBBTC).allowance(address(DEPLOYED_UTILS), ZEROX_ALLOWANCE_HOLDER), 0);
    }

    function _quote(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        string memory opType
    ) internal returns (ZeroXQuote memory quote) {
        string memory url = string.concat(
            "https://api.revert.finance/v1/quote0x_v2?network=mainnet&sellToken=",
            vm.toString(sellToken),
            "&buyToken=",
            vm.toString(buyToken),
            "&sellAmount=",
            vm.toString(sellAmount),
            "&slippageBps=100&opType=",
            opType,
            "&poolFeeTier=737869762948382&taker=",
            vm.toString(address(DEPLOYED_UTILS))
        );
        string[] memory command = new string[](5);
        command[0] = "bash";
        command[1] = "-c";
        command[2] = string.concat(
            "set -euo pipefail; response=$(curl --silent --show-error --fail-with-body --max-time 30 ",
            "-H 'Origin: https://develop.revert.finance' -H 'Referer: https://develop.revert.finance/' ",
            "-H 'User-Agent: EkuboUtils-Gauntlet/1.0' \"$1\"); ",
            "amount=$(jq -er '.data.minBuyAmount' <<<\"$response\"); ",
            "data=$(jq -er '.data.transaction.data' <<<\"$response\"); ",
            "cast abi-encode 'f(uint256,bytes)' \"$amount\" \"$data\""
        );
        command[3] = "--";
        command[4] = url;
        quote.amountIn = sellAmount;
        (quote.amountOutMin, quote.data) = abi.decode(vm.ffi(command), (uint256, bytes));
        assertGt(quote.amountOutMin, 0, "0x quote must have nonzero minimum output");
        assertGt(quote.data.length, 4, "0x quote must have executable calldata");
    }

    function _changedTokenId(
        Vm.Log[] memory logs,
        uint256 oldTokenId
    ) internal pure returns (uint256 newTokenId) {
        bytes32 topic = keccak256("ChangeRange(uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == oldTokenId) {
                return uint256(logs[i].topics[2]);
            }
        }
        revert("ChangeRange event not found");
    }

    function _deployUtils() internal returns (EkuboUtils) {
        return new EkuboUtils(POSITIONS, CORE, IWETH9(WETH), ZEROX_ALLOWANCE_HOLDER, IPermit2(PERMIT2));
    }

    function _signPermit2Batch(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        uint256 privateKey,
        address spender
    ) internal returns (bytes memory) {
        bytes32 permitBatchTypehash = keccak256(
            "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );
        bytes32 tokenPermissionsTypehash = keccak256("TokenPermissions(address token,uint256 amount)");
        bytes32[] memory permissionHashes = new bytes32[](permit.permitted.length);
        for (uint256 i; i < permit.permitted.length; ++i) {
            permissionHashes[i] =
                keccak256(abi.encode(tokenPermissionsTypehash, permit.permitted[i].token, permit.permitted[i].amount));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                permitBatchTypehash,
                keccak256(abi.encodePacked(permissionHashes)),
                spender,
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IPermit2(PERMIT2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return bytes.concat(r, s, bytes1(v));
    }

    function _mainnetRpcUrl() internal returns (string memory rpcUrl) {
        try vm.envString("MAINNET_RPC_URL") returns (string memory configuredUrl) {
            rpcUrl = configuredUrl;
        } catch {}
    }

    function _poolKey() internal pure returns (EkuboPoolKey memory) {
        return EkuboPoolKey({
            token0: WBTC,
            token1: CBBTC,
            // extension=0, fee=737869762948382, concentrated=true, tickSpacing=150
            config: 0x000000000000000000000000000000000000000000029f16b11c6d1e80000096
        });
    }
}
