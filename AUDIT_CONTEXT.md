# Audit Context

## Audit target

Audit the repository at the exact `HEAD` supplied for the audit. Record that
commit and the recursively pinned git-submodule revisions in the final report.
Clone with recursive submodules enabled:

```bash
git clone --recurse-submodules https://github.com/revert-finance/ekubo-utils.git
```

This contract has not been deployed. The previous EkuboUtils deployment at
`0x93E1b9729f745B3D450EB7CDd8085649AF405102` is obsolete,
ABI-incompatible, and outside this audit's scope.

## Protocol context

The only deployment target is Ethereum mainnet and Ekubo EVM contracts
v3.2.0.

Ekubo is a singleton concentrated-liquidity AMM with extensions. It is not a
Uniswap fork. Do not infer its authorization, pool, position, fee, accounting,
or callback behavior from Uniswap.

Only canonical concentrated pools with no extension are supported. Stableswap
and extension pools are intentionally rejected.

The implementation used Revert's current V3Utils security model as a design
reference:

<https://github.com/revert-finance/lend/blob/4f1e12715c37915b3774d943b8c54646485eed50/src/transformers/V3Utils.sol>

This is not a request for behavioral parity where Ekubo differs from Uniswap.

## Trusted external contracts

Assume the canonical deployed implementations of Ekubo Core, Ekubo Positions,
WETH, Permit2, Universal Router, and 0x AllowanceHolder are not malicious. Their
mainnet addresses are pinned in `script/DeployEkuboUtils.s.sol`.

Re-auditing those external projects is out of scope. The following integration
properties remain in scope:

- ABI and authorization assumptions;
- token, native-currency, and NFT custody;
- payer and recipient identity;
- allowance lifecycle;
- callback behavior and reentrancy exposure;
- malformed or adversarial router calldata;
- incorrect assumptions about the external contracts' behavior.

## Threat model

Treat callers, ERC20 tokens, NFT operators, recipients, Permit2 payloads,
quotes, swap calldata, and action parameters as adversarial.

An approved ERC721 operator must not be able to redirect or steal an owner's
position or proceeds.

The Revert application normally exposes writes only for NFTs containing one
supported canonical position component. This is not a contract-level security
boundary: direct callers can supply multi-component NFTs, incorrect pool keys,
incorrect ranges, arbitrary recipients, and malformed action envelopes. The
contract must fail safely or preserve ownership and asset security in those
cases.

0x and Universal Router calldata are supplied by the caller. The execution
targets are pinned, but the calldata must still be treated as hostile.

There is no oracle-based price protection. Deadlines and caller-supplied
minimum output and liquidity values are the intended economic protection. MEV
or price movement within those explicit bounds is accepted.

The contract is intentionally immutable, ownerless, and non-upgradeable. It has
no administrative or rescue path.

## Security invariants

- Existing-position actions may custody the NFT only atomically and must return
  it to the initiating owner.
- No standing ERC721 operator approval should be required.
- Approved NFT operators must not be able to choose action recipients.
- Unspent tokens and native currency must be returned to the correct payer.
- EkuboUtils should not retain user funds after successful execution.
- ERC20, Ekubo Positions, and 0x allowances must be exact and cleared after
  successful use.
- Permit2 signatures must bind the intended owner, spender, tokens, amounts,
  and nonce.
- `CHANGE_RANGE` must withdraw the specified component's entire current
  liquidity and collect its fees before minting the replacement range.
- Partial range moves must revert.
- Deadlines and minimum outputs or liquidity must be enforced before relevant
  external effects.
- Fee-on-transfer funding is intentionally rejected.
- Unsupported pools and actions must fail safely.
- Reentrancy through token, NFT, Ekubo, or router callbacks must not permit
  unauthorized execution, double spending, or incorrect payer or recipient
  use.

## Intended product behavior

The application supports:

- swap;
- swap and mint;
- increase liquidity through an owner-initiated `safeTransferFrom` NFT
  callback;
- withdraw and collect;
- withdraw and consolidate through a swap;
- compound fees;
- full-liquidity range changes.

Permit2 batch entries must be ordered as follows, omitting entries whose
required amount is zero:

1. pool token0;
2. pool token1;
3. a distinct swap-source token, if required.

Universal Router commands use `payerIsUser = false`, send outputs to
EkuboUtils, and sweep unused input back to EkuboUtils.

The outer EkuboUtils deadline must always be enforced. Universal Router also
has its own payload deadline. Router-specific expiry must not replace the
utility-level deadline.

## Accepted limitations

The following limitations are known and accepted. Findings that demonstrate a
greater impact or a way to exploit another user remain in scope.

- An NFT sent with plain `transferFrom` bypasses `onERC721Received` and is
  unrecoverable because the utility intentionally has no owner or rescue path.
- Stray ETH held by Ekubo Positions can temporarily revert exact native-refund
  accounting until its permissionless `refundNativeToken()` is called.
- The frontend excludes extension, stableswap, unsupported, and multi-component
  positions from write actions.
- The contract is immutable, ownerless, and non-upgradeable.

## Expected audit output

Classify findings by severity and distinguish between:

- exploitable contract vulnerabilities;
- Ekubo integration misunderstandings;
- unsafe frontend or integrator requirements;
- accepted limitations;
- test and documentation gaps.

For every finding, provide an executable attack path or violated invariant,
the affected functions, all required assumptions, and a concrete remediation.
