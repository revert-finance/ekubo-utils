// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IEkuboPositions} from "../src/interfaces/IEkuboPositions.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {EkuboUtils} from "../src/EkuboUtils.sol";
import {EkuboPoolKey} from "../src/interfaces/IEkuboPositions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFynd {
    function accumulatePoolFees(
        EkuboPoolKey memory key
    ) external;
}

interface IFeeRate {
    function SWAP_PROTOCOL_FEE_X64() external view returns (uint64);
}

/// @notice Mandatory fork suite. Requires MAINNET_RPC_URL; never silently skips.
/// @dev Saved-fee seeding models pending swap fees, not a mocked getter. The exact
/// Core saved-balances layout comes from the verified deployed extension's
/// CoreStorageLayout.savedBalancesSlot and _loadSavedFees (each balance stores +1).
/// Both Core custody balances are increased by the same seeded amount. All real
/// extension callbacks, fee growth, Positions protocol fees and transfers execute.
contract FyndMainnetForkTest is Test {
    IEkuboPositions internal constant POSITIONS = IEkuboPositions(0x02D9876A21AF7545f8632C3af76eC90b5ad4b66D);
    address internal constant CORE = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant EXT = 0x55b703eED01b35641963da2FB2E14885993605A3;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant OLD_UTILS = 0x4Cf798c93280E2103Ae1186B4D4AB7E9CE93df9f;
    bytes32 constant CONFIG = 0x55b703eed01b35641963da2fb2e14885993605a3000000000000000080000400;
    EkuboUtils private fynd;
    EkuboUtils.PositionSpec private active;
    address private alice;
    uint256 private initialNativeBalance;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        assertEq(block.chainid, 1);
        assertGt(EXT.code.length, 0);
        fynd = new EkuboUtils(
            POSITIONS,
            CORE,
            IWETH9(WETH),
            0x0000000000001fF3684f28c67538d4D072C22734,
            IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3)
        );
        // CREATE addresses can already hold forced ETH on the fork. Never consume that baseline.
        initialNativeBalance = address(fynd).balance;
        alice = makeAddr("fynd-owner");
        EkuboPoolKey memory key = EkuboPoolKey(address(0), USDC, CONFIG);
        int32 tick = int32(uint32(uint256(vm.load(CORE, keccak256(abi.encode(key)))) >> 128));
        int32 center = tick / 1024 * 1024;
        active = EkuboUtils.PositionSpec(key, center - 10240, center + 10240);
        deal(alice, 100 ether);
        deal(WETH, alice, 10 ether);
        deal(USDC, alice, 100_000e6);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(fynd), type(uint256).max);
        IERC20(USDC).approve(address(fynd), type(uint256).max);
        vm.stopPrank();
    }

    function _mintParams() private view returns (EkuboUtils.SwapAndMintParams memory p) {
        p.position = active;
        p.amount0 = 1 ether;
        p.amount1 = 5000e6;
        p.recipient = alice;
        p.recipientNFT = alice;
        p.deadline = block.timestamp;
        p.minLiquidity = 1;
    }

    function _create() private returns (uint256 id) {
        vm.prank(alice);
        (id,,,) = fynd.swapAndMint(_mintParams());
        assertEq(POSITIONS.ownerOf(id), alice);
        assertGt(_liquidity(id, active), 0);
        _clean();
    }

    function _liquidity(
        uint256 id,
        EkuboUtils.PositionSpec memory p
    ) private view returns (uint128 l) {
        (l,,,,) = POSITIONS.getPositionFeesAndLiquidity(id, p.poolKey, p.tickLower, p.tickUpper);
    }

    function _instructions() private view returns (EkuboUtils.Instructions memory i) {
        i.position = active;
        i.recipient = alice;
        i.recipientNFT = alice;
        i.deadline = block.timestamp;
        i.collectFees = true;
        i.whatToDo = EkuboUtils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
    }

    function _execute(
        uint256 id,
        EkuboUtils.Instructions memory i
    ) private {
        vm.prank(alice);
        POSITIONS.safeTransferFrom(
            alice, address(fynd), id, abi.encode(EkuboUtils.NftTransferAction.EXECUTE, abi.encode(i))
        );
        assertEq(POSITIONS.ownerOf(id), alice);
        _clean();
    }

    function _clean() private {
        assertEq(IERC20(WETH).balanceOf(address(fynd)), 0);
        assertEq(IERC20(USDC).balanceOf(address(fynd)), 0);
        assertEq(address(fynd).balance, initialNativeBalance);
        assertEq(IERC20(USDC).allowance(address(fynd), address(POSITIONS)), 0);
    }

    function _seedFees() private {
        bytes32 poolId = keccak256(abi.encode(active.poolKey));
        bytes32 slot = keccak256(abi.encode(EXT, address(0), USDC, poolId));
        uint256 saved = uint256(vm.load(CORE, slot));
        uint256 f0 = uint128(saved >> 128);
        uint256 f1 = uint128(saved);
        if (f0 == 0) f0 = 1;
        if (f1 == 0) f1 = 1;
        vm.store(CORE, slot, bytes32(((f0 + 0.1 ether) << 128) | (f1 + 300e6)));
        deal(CORE, CORE.balance + 0.1 ether);
        deal(USDC, CORE, IERC20(USDC).balanceOf(CORE) + 300e6);
        vm.warp(block.timestamp + 1);
    }

    function testFyndOldDeploymentRejectsExtension() external {
        vm.prank(alice);
        vm.expectRevert(EkuboUtils.ExtensionsNotSupported.selector);
        EkuboUtils(payable(OLD_UTILS)).swapAndMint(_mintParams());
    }

    function testFyndCreateIncreaseWithdrawRangeAndOwnership() external {
        uint256 id = _create();
        uint128 beforeL = _liquidity(id, active);
        EkuboUtils.SwapAndIncreaseLiquidityParams memory p;
        p.tokenId = id;
        p.position = active;
        p.amount0 = 0.1 ether;
        p.amount1 = 500e6;
        p.recipient = alice;
        p.deadline = block.timestamp;
        p.minLiquidity = 1;
        vm.prank(alice);
        POSITIONS.safeTransferFrom(
            alice, address(fynd), id, abi.encode(EkuboUtils.NftTransferAction.INCREASE_LIQUIDITY, abi.encode(p))
        );
        assertEq(POSITIONS.ownerOf(id), alice);
        assertGt(_liquidity(id, active), beforeL);
        _clean();
        EkuboUtils.Instructions memory i = _instructions();
        uint128 l = _liquidity(id, active);
        i.liquidity = l / 2;
        uint256 wBefore = IERC20(WETH).balanceOf(alice);
        uint256 uBefore = IERC20(USDC).balanceOf(alice);
        _execute(id, i);
        assertEq(_liquidity(id, active), l - i.liquidity);
        assertGt(IERC20(WETH).balanceOf(alice), wBefore);
        assertGt(IERC20(USDC).balanceOf(alice), uBefore);
        i.whatToDo = EkuboUtils.WhatToDo.CHANGE_RANGE;
        i.liquidity = _liquidity(id, active);
        i.newPosition = active;
        i.newPosition.tickLower -= 1024;
        i.newPosition.tickUpper += 1024;
        i.minLiquidity = 1;
        vm.startPrank(alice);
        POSITIONS.approve(address(fynd), id);
        uint256 newId = fynd.execute(id, i);
        vm.stopPrank();
        assertEq(POSITIONS.ownerOf(id), alice);
        assertEq(POSITIONS.ownerOf(newId), alice);
        assertEq(_liquidity(id, active), 0);
        assertGt(_liquidity(newId, i.newPosition), 0);
        _clean();
    }

    function testFyndPendingFeesCollectExactlyOnceAndCompound() external {
        uint256 id = _create();
        _seedFees();
        (,,, uint128 stale0, uint128 stale1) =
            POSITIONS.getPositionFeesAndLiquidity(id, active.poolKey, active.tickLower, active.tickUpper);
        uint256 snapshot = vm.snapshot();
        IFynd(EXT).accumulatePoolFees(active.poolKey);
        (,,, uint128 gross0, uint128 gross1) =
            POSITIONS.getPositionFeesAndLiquidity(id, active.poolKey, active.tickLower, active.tickUpper);
        assertGt(gross0, stale0);
        assertGt(gross1, stale1);
        assertTrue(vm.revertTo(snapshot));
        uint256 wBefore = IERC20(WETH).balanceOf(alice);
        uint256 uBefore = IERC20(USDC).balanceOf(alice);
        uint128 l = _liquidity(id, active);
        _execute(id, _instructions());
        uint256 rate = IFeeRate(address(POSITIONS)).SWAP_PROTOCOL_FEE_X64();
        uint256 net0 = gross0 - ((uint256(gross0) * rate + (1 << 64) - 1) >> 64);
        uint256 net1 = gross1 - ((uint256(gross1) * rate + (1 << 64) - 1) >> 64);
        assertEq(IERC20(WETH).balanceOf(alice) - wBefore, net0);
        assertEq(IERC20(USDC).balanceOf(alice) - uBefore, net1);
        assertEq(_liquidity(id, active), l);
        wBefore = IERC20(WETH).balanceOf(alice);
        uBefore = IERC20(USDC).balanceOf(alice);
        _execute(id, _instructions());
        assertEq(IERC20(WETH).balanceOf(alice), wBefore);
        assertEq(IERC20(USDC).balanceOf(alice), uBefore);
        _seedFees();
        EkuboUtils.Instructions memory i = _instructions();
        i.whatToDo = EkuboUtils.WhatToDo.COMPOUND_FEES;
        i.minLiquidity = 1;
        _execute(id, i);
        assertGt(_liquidity(id, active), l);
    }
}
