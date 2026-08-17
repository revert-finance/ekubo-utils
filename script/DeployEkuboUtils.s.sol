// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";

import {EkuboUtils} from "../src/EkuboUtils.sol";
import {IEkuboPositions} from "../src/interfaces/IEkuboPositions.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @notice Deploys the mainnet-only EkuboUtils configuration used by Revert.
contract DeployEkuboUtils is Script {
    error MissingContractCode(address target);
    error UnsupportedChain(uint256 chainId);

    uint256 internal constant MAINNET_CHAIN_ID = 1;

    IEkuboPositions internal constant POSITIONS = IEkuboPositions(0x02D9876A21AF7545f8632C3af76eC90b5ad4b66D);
    address internal constant CORE = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    IWETH9 internal constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function run() external returns (EkuboUtils deployed) {
        if (block.chainid != MAINNET_CHAIN_ID) revert UnsupportedChain(block.chainid);
        _assertContract(address(POSITIONS));
        _assertContract(CORE);
        _assertContract(address(WETH));
        _assertContract(UNIVERSAL_ROUTER);
        _assertContract(ZEROX_ALLOWANCE_HOLDER);
        _assertContract(address(PERMIT2));

        vm.startBroadcast();
        deployed = new EkuboUtils(POSITIONS, CORE, WETH, UNIVERSAL_ROUTER, ZEROX_ALLOWANCE_HOLDER, PERMIT2);
        vm.stopBroadcast();

        console2.log("EkuboPositions", address(POSITIONS));
        console2.log("EkuboCore", CORE);
        console2.log("WETH", address(WETH));
        console2.log("UniversalRouter", UNIVERSAL_ROUTER);
        console2.log("0xAllowanceHolder", ZEROX_ALLOWANCE_HOLDER);
        console2.log("Permit2", address(PERMIT2));
        console2.log("EkuboUtils", address(deployed));
    }

    function _assertContract(
        address target
    ) internal view {
        if (target.code.length == 0) revert MissingContractCode(target);
    }
}
