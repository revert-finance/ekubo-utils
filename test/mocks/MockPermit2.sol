// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";

contract MockPermit2 {
    using SafeERC20 for IERC20;

    function permitTransferFrom(
        IPermit2.PermitBatchTransferFrom memory permit,
        IPermit2.SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata
    ) external {
        require(permit.permitted.length == transferDetails.length, "length");
        for (uint256 i; i < transferDetails.length; ++i) {
            require(transferDetails[i].requestedAmount <= permit.permitted[i].amount, "amount");
            IERC20(permit.permitted[i].token)
                .safeTransferFrom(owner, transferDetails[i].to, transferDetails[i].requestedAmount);
        }
    }
}
