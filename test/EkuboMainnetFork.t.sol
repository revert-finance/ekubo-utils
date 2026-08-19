// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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
    uint256 internal constant TOKEN_ID = 115405844744126724027399150793600264461049412098266383761154101033925042376216;

    function testMainnetPositionAbiAndPoolConfig() external {
        string memory rpcUrl = _mainnetRpcUrl();
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);

        assertGt(address(POSITIONS).code.length, 0);
        assertGt(CORE.code.length, 0);
        (uint128 liquidity,,,,) = POSITIONS.getPositionFeesAndLiquidity(TOKEN_ID, _poolKey(), 0, 450);
        assertGt(liquidity, 0);
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
