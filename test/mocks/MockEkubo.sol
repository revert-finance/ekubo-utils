// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EkuboPoolKey, IEkuboPositions} from "../../src/interfaces/IEkuboPositions.sol";

contract MockCore {
    receive() external payable {}
}

contract MockEkuboPositions is ERC721 {
    using SafeERC20 for IERC20;

    MockCore public immutable core;
    uint256 public nextId = 1;

    struct Position {
        uint128 liquidity;
        uint128 amount0;
        uint128 amount1;
        uint128 fees0;
        uint128 fees1;
    }

    mapping(uint256 => Position) public positionState;

    constructor(
        MockCore _core
    ) ERC721("Ekubo Position", "EKP") {
        core = _core;
    }

    function mintTo(
        address to,
        Position memory state
    ) external returns (uint256 id) {
        id = nextId++;
        positionState[id] = state;
        _mint(to, id);
    }

    /// @dev Mirrors Ekubo Positions, which requires the receiver callback even
    /// when `to` has no code. This differs from standard ERC721 safe transfers
    /// and keeps the utility's EOA return path covered by unit tests.
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override {
        transferFrom(from, to, tokenId);
        require(
            IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data)
                == IERC721Receiver.onERC721Received.selector,
            "unsafe recipient"
        );
    }

    function seedFees(
        uint256 id,
        uint128 fees0,
        uint128 fees1
    ) external {
        positionState[id].fees0 += fees0;
        positionState[id].fees1 += fees1;
    }

    function getPositionFeesAndLiquidity(
        uint256 id,
        EkuboPoolKey memory,
        int32,
        int32
    ) external view returns (uint128 liquidity, uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1) {
        Position memory p = positionState[id];
        return (p.liquidity, p.amount0, p.amount1, p.fees0, p.fees1);
    }

    function deposit(
        uint256 id,
        EkuboPoolKey memory poolKey,
        int32,
        int32,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) public payable returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        require(_isApprovedOrOwner(msg.sender, id), "not authorized");
        amount0 = maxAmount0 / 2;
        amount1 = maxAmount1 / 2;
        liquidity = uint128(uint256(amount0) + amount1);
        require(liquidity >= minLiquidity, "slippage");
        _take(poolKey.token0, msg.sender, amount0);
        _take(poolKey.token1, msg.sender, amount1);
        Position storage p = positionState[id];
        p.liquidity += liquidity;
        p.amount0 += amount0;
        p.amount1 += amount1;
    }

    function withdraw(
        uint256 id,
        EkuboPoolKey memory poolKey,
        int32,
        int32,
        uint128 liquidity,
        address recipient,
        bool withFees
    ) external payable returns (uint128 amount0, uint128 amount1) {
        require(_isApprovedOrOwner(msg.sender, id), "not authorized");
        Position storage p = positionState[id];
        require(liquidity <= p.liquidity, "liquidity");
        if (p.liquidity != 0) {
            amount0 = uint128(uint256(p.amount0) * liquidity / p.liquidity);
            amount1 = uint128(uint256(p.amount1) * liquidity / p.liquidity);
        }
        p.amount0 -= amount0;
        p.amount1 -= amount1;
        p.liquidity -= liquidity;
        if (withFees) {
            amount0 += p.fees0;
            amount1 += p.fees1;
            p.fees0 = 0;
            p.fees1 = 0;
        }
        _send(poolKey.token0, recipient, amount0);
        _send(poolKey.token1, recipient, amount1);
    }

    function mintAndDeposit(
        EkuboPoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = nextId++;
        _mint(msg.sender, id);
        (liquidity, amount0, amount1) = deposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity);
    }

    function multicall(
        bytes[] calldata data
    ) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i < data.length; ++i) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            if (!success) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            results[i] = result;
        }
    }

    function refundNativeToken() external payable {
        (bool success,) = msg.sender.call{value: address(this).balance}("");
        require(success);
    }

    function _take(
        address token,
        address from,
        uint128 amount
    ) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            require(msg.value >= amount, "value");
            (bool success,) = address(core).call{value: amount}("");
            require(success);
        } else {
            IERC20(token).safeTransferFrom(from, address(core), amount);
        }
    }

    function _send(
        address token,
        address recipient,
        uint128 amount
    ) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool success,) = recipient.call{value: amount}("");
            require(success);
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    receive() external payable {}
}
