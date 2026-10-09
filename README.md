# On-Chain Oppenheimer (NUKE)

A fixed-supply ERC-20 token for an IdentityMD custom-token launch on Ethereum mainnet.

| Property | Value |
|---|---|
| Solidity contract | `NukeToken` (`src/NukeToken.sol`) |
| `name()` | `On-Chain Oppenheimer` |
| `symbol()` | `NUKE` |
| `decimals()` | `18` |
| `totalSupply()` | `1_000_000_000 * 10**18` = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minting | once, in the constructor, the whole supply to `msg.sender`; no mint function exists |
| Admin powers | none: no owner, pause, blacklist, freeze, fee, burn-on-transfer or upgrade path |
| Compiler | solc `0.8.26`, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

## Layout

```
foundry.toml                       compiler pins and build settings (root project; forge runs here)
remappings.txt                     forge-std/ -> lib/forge-std/src/
src/NukeToken.sol                  the token
src/interfaces/IERC20.sol          the ERC-20 interface the token implements
script/DeployNukeToken.s.sol       reviewable standalone deployment (not used by the launch)
test/NukeToken.t.sol               unit tests: metadata, mint, transfer/approve/transferFrom success and failure, fuzz
test/NukeTokenLaunchFlow.t.sol     launch-flow simulation: CREATE2 from a factory, 10/88/2 split, no admin reach
test/NukeToken.invariant.t.sol     invariant: supply constant and equal to the sum of balances under random activity
test/DeployNukeToken.t.sol         the deploy script's logic, called directly with no environment
lib/forge-std/                     forge-std v1.11.0 (commit 8e40513d), vendored as plain files (no submodule)
```

## Behaviour

The token is a deliberately plain ERC-20:

- `transfer` and `transferFrom` move exactly the amount requested, to anyone, from anyone. There is no
  tax, reflection, burn, cooldown, max-wallet or max-transaction rule, so every launch flow (factory to
  MerkleDistributor, factory to PoolManager seed, distributor to claimant, trader buy and sell through the
  PoolManager, remainder to the requester) arrives whole. Nothing is exempted because nothing needs to be.
- `approve` overwrites the allowance. An allowance of `type(uint256).max` is treated as infinite and is
  not decremented by `transferFrom`.
- Transfers to the zero address and approvals of the zero spender revert with `ZeroAddress()`.
  Overspending reverts with `InsufficientBalance(from, balance, needed)` or
  `InsufficientAllowance(spender, allowance, needed)`.
- Plain ETH sent to the contract and unknown selectors revert.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and the constructor makes no
  external call, so it deploys on an empty chain.
- `totalSupply()` is a compile-time constant. Nobody, including the deployer or the factory, can increase
  or decrease it. Holders who want to burn can send to an address they do not control, but the contract
  offers no burn function (the brief did not ask for one).

## Assumptions

- The brief asks for a plain token with a fixed supply minted once to the deployer. No additional
  features (tax, vesting, governance, burn, owner) were requested, so none were added. Adding any later
  changes the bytecode and therefore the launch manifest.
- The launch chain is Ethereum mainnet (chain id 1) and the pool pairs with IMD
  (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`). The token does not reference either: it carries no
  chain-specific constants and is deployable anywhere.
- At launch the deployer is the IdentityMD ProjectFactory, so the factory holds the full supply after
  construction and distributes it per the launch policy. The token neither knows nor checks who deploys it.
- Launch economics (from the job, copied into `launch.json` by the manifest step, not by this repository):
  `poolBps = 8800`, `initialMarketCapWei = 2500000000000000000000` (2,500 IMD),
  `remainderTo = 0x6bf192ebef135e0f645e99d59d9bf44e7711606c`. With the swarm's fixed 10%, the split of
  the 1,000,000,000 NUKE supply is 100,000,000 to the MerkleDistributor, 880,000,000 to seed the pool and
  20,000,000 to `remainderTo`. `test_fullLaunchSplitIsExact` checks the arithmetic is exact in minor units.
- Pool parameters are the launch's, not the token's: fee `12500` (1.25%), tick spacing `60`, opening
  price derived by the deployer from the market cap. Nothing in this repository sets or depends on them.

## Deployment parameters

The constructor takes no arguments, so there is nothing to configure. For the manifest step:

| Manifest field | Value |
|---|---|
| `token.contract` | `NukeToken` |
| `token.name` | `On-Chain Oppenheimer` |
| `token.symbol` | `NUKE` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `contracts` | `[]` (no application contracts) |

`launch.json` is written by the manifest step after acceptance; this repository intentionally does not
contain one.

### Standalone deployment (outside the launch)

`script/DeployNukeToken.s.sol` deploys the token with one transaction. It reads no environment
variables; the broadcasting signer becomes the holder of the supply.

```
forge script script/DeployNukeToken.s.sol --rpc-url <RPC> --account <KEYSTORE> --broadcast
```

Verify afterwards with `forge verify-contract <ADDRESS> src/NukeToken.sol:NukeToken --chain 1`
(no constructor arguments to encode).

## After launch

There is nothing to set. The token has no owner-settable storage, no external dependencies and no
configuration. Operational responsibilities are limited to:

- **Explorer verification** of the deployed `NukeToken` source (the deployer's job; the build is
  reproducible because the metadata hash is omitted).
- **Key custody for `remainderTo`**: the 2% remainder is sent to `0x6bf192ebef135e0f645e99d59d9bf44e7711606c`.
  The requester must control that address; the token cannot recover tokens sent anywhere.
- **No rescue path**: tokens sent to a wrong address or to the token contract itself are irrecoverable by
  design, since no privileged function exists. Communicate this to holders.

## Security notes

Checked against the `eth-security` reference checklist:

- No external calls, so no reentrancy surface. State changes happen before the only "interaction",
  which is the event emission.
- Arithmetic is checked except in two `unchecked` blocks guarded immediately above by a comparison;
  no balance can exceed the constant supply, so the credit cannot overflow.
- No `tx.origin`, no timestamps, no randomness, no oracle, no proxy, no `selfdestruct`.
- The approve front-running race inherent to ERC-20 is documented in `approve`'s docstring; callers
  changing a non-zero allowance should set it to zero first. `increaseAllowance`/`decreaseAllowance`
  were not added to keep the interface to the standard the launch floor exercises.
- Tools run: `forge build`, `forge test` (unit, fuzz, invariant), `forge fmt --check`. Slither and
  Mythril were not available in this environment. Tests passing are not an audit; an independent
  adversarial review is still recommended before the launch is admitted.

## Checks

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables and do not depend on the calling address, so they pass in any
order, in parallel and with an empty environment (`env -i forge test`).
