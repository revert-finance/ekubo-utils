# Ekubo Utils

Standalone Ekubo v3.2.0 position utility, designed from the current Revert `V3Utils` behavior rather than the legacy
Ekubo prototype.

The contract supports swaps, swap-and-mint, owner-initiated swap-and-increase via direct NFT transfer, compounding,
range changes, and withdraw/collect/swap for canonical concentrated pools on Ekubo. Extension and stableswap pools
are deliberately rejected.

Security-relevant design choices:

- Position NFTs are held only during an operation and always returned to their original owner. Owners may send an NFT
  directly with an encoded action, so adding liquidity does not require leaving an ERC-721 operator approval behind.
- Only an NFT owner can initiate a position operation; approved third-party NFT operators cannot choose recipients.
- ERC-20 deposits approve Ekubo Positions (the caller that executes the flash-accountant transfer), for an exact amount,
  and revoke afterward. Assets are transferred directly to Core.
- 0x AllowanceHolder allowances are exact and revoked after each successful swap. The input spend is measured from
  the remaining allowance, so any third-party inflow of the input token during execution reverts instead of being
  treated as unspent input or swap output.
- Two-leg swap-and-mint legs must each produce only their declared pool-token output; a side output of the other
  pool token reverts rather than being stranded unaccounted in the utility.
- Wallet funding supports exact balance-checked transfers or Permit2 batch signature transfers.
- Swaps accept only raw 0x Swap API v2 calldata and call only the configured 0x AllowanceHolder.
- All public state-changing operations have transaction deadlines and output/liquidity slippage bounds.
- `CHANGE_RANGE` must remove the position's full current liquidity. Partial requests revert rather than silently
  splitting one product-level position into an old NFT and a newly ranged NFT. It must also collect the old range's
  fees, so the old NFT does not retain value after the move.

Dependencies are pinned as git submodules in `lib/`. Clone with submodules enabled:

```bash
git clone --recurse-submodules https://github.com/revert-finance/ekubo-utils.git
```

Security reviewers should read [AUDIT_CONTEXT.md](AUDIT_CONTEXT.md) for the
threat model, trust boundaries, invariants, accepted limitations, and expected
audit output.

## Direct NFT actions

An NFT owner can invoke either position-management mode without approving an ERC-721 operator:

```solidity
positions.safeTransferFrom(
    owner,
    address(ekuboUtils),
    tokenId,
    abi.encode(EkuboUtils.NftTransferAction.EXECUTE, abi.encode(instructions))
);

positions.safeTransferFrom(
    owner,
    address(ekuboUtils),
    tokenId,
    abi.encode(EkuboUtils.NftTransferAction.INCREASE_LIQUIDITY, abi.encode(increaseParams))
);
```

The call must be initiated by the owner, not an approved NFT operator. The original NFT is returned to that same owner
before the call completes. ERC-20 inputs can use an ordinary exact approval to `EkuboUtils` or a Permit2 signature.
Because an ERC-721 transfer cannot carry ETH, native-pool inputs for this direct path are supplied as WETH and unwrapped
inside the utility.

Ekubo Positions requires an ERC721 receiver callback even when `safeTransferFrom` targets an EOA. EkuboUtils therefore
returns NFTs to EOAs with `transferFrom`, while contract recipients retain `safeTransferFrom` and its callback data.

Unlike V3Utils, there is no `executeWithPermit`: Ekubo's Positions NFT does not expose the Uniswap V3 EIP-712 NFT permit
method. Direct owner transfers provide the approval-free position-action path instead.

## Permit2 funding order

`permitData` is `abi.encode(PermitBatchTransferFrom, signature)`. Its `permitted` entries must use this exact order,
omitting entries whose required amount is zero:

1. pool token0
2. pool token1
3. `swapSourceToken`, only when it is different from both pool tokens

Each entry must name the corresponding token. The Permit2 signature's spender is `EkuboUtils`; the signed owner is the
transaction caller for `swap`/`swapAndMint`, or the NFT owner (`from`) for an owner-initiated increase-liquidity transfer.

## Swap payloads

### 0x Swap API v2

Pass the quote's raw transaction calldata. The quote taker must be `EkuboUtils`, and token approval must target the
mainnet 0x AllowanceHolder configured in the deployment. EkuboUtils grants that holder only the exact input allowance
for the call and clears it afterward.

## Operational limitations

- Sending an Ekubo NFT with plain `transferFrom` bypasses `onERC721Received` and leaves it permanently held by this
  ownerless utility. Integrators must use the four-argument `safeTransferFrom` action envelope documented above.
- Native-pool deposits expect Ekubo Positions not to hold unrelated ETH. If stray ETH is present, the utility's exact
  refund check reverts until someone calls Positions' permissionless `refundNativeToken()`.
- No-swap withdrawals emit `WithdrawAndCollect(tokenId, amount0, amount1)`. Consolidating withdrawals emit
  `WithdrawAndCollectAndSwap(tokenId, targetToken, targetAmount)`.

## Test and deploy

Run the deterministic unit suite and contract-size check from the repository root:

```bash
forge test
forge build --sizes
```

Set `MAINNET_RPC_URL` to run the optional fork scenarios against the real Ekubo Positions and Permit2 contracts. The
deployment script is mainnet-only, pins all five constructor dependencies, and rejects any dependency without deployed
code:

```bash
forge script script/DeployEkuboUtils.s.sol:DeployEkuboUtils \
  --rpc-url "$MAINNET_RPC_URL" \
  --account deployer \
  --broadcast \
  --slow \
  --verify \
  -vvvv
```

After verification, update the pinned `protocols/ekubo-utils` submodule commit and register the new address in the
Revert monorepo's `apps/revert-spa/src/cljc/revert/abis.cljc`. Deploy the SPA with the Ekubo action flag still off,
validate quotes and writes in integration, and only then enable the flag.
