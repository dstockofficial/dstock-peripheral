# DStock Peripheral

Peripheral contracts for the DStock ecosystem, providing LayerZero-integrated bridge and router functionality for cross-chain token operations.

## Overview

This repository contains contracts that enable:

- **One-click wrap and bridge**: Wrap underlying tokens (BSC-local ERC20 or OFT assets) and bridge shares to destination chains in a single transaction
- **Automatic unwrapping**: LayerZero compose messages can trigger unwrapping of shares into the configured underlying token (and optionally deliver locally on the same chain)

## Contracts

- **DStockComposerRouter**: Unified router that supports:
  - user-initiated wrap + bridge (`wrapAndBridge`, `quoteWrapAndBridge`)
  - LayerZero compose handling for forward and reverse routes (`lzCompose`)

## How it works (quick mental model)

`DStockComposerRouter` supports two kinds of entrypoints:

- **User entry (EOA calls)**:
  - `wrapAndBridge(underlying, amount, dstEid, to, extraOptions)`
  - `quoteWrapAndBridge(underlying, amount, dstEid, to, extraOptions)`

- **Compose entry (LayerZero Endpoint calls)**:
  - `lzCompose(_oApp, _guid, _message, ...)`

### Forward vs Reverse (compose)

- **Forward compose**:
  - `_oApp == underlying` (the token that was credited to this router)
  - router wraps underlying into wrapper shares
  - router bridges shares via `shareAdapter`

- **Reverse compose**:
  - `_oApp == shareAdapter` (shares adapter credited shares to this router)
  - router unwraps shares into `underlying`
  - if `finalDstEid == chainEid`: deliver underlying locally to the EVM address encoded in `finalTo`
  - else: bridge underlying via `underlying.send(...)`

## Configuration (owner/admin)

The router uses a minimal registry. The owner configures routes via:

- `setRouteConfig(underlying, wrapper, shareAdapter)`
  - always sets reverse mapping: `shareAdapter -> wrapper`
  - if `underlying != address(0)`: also sets forward mapping: `underlying -> (wrapper, shareAdapter)`

Notes:
- A single `(wrapper, shareAdapter)` pair can be reused by multiple underlyings (call `setRouteConfig` multiple times).
- `underlying` can be a **BSC-local ERC20** or an **EVM OFT token/adapter** address, as long as the wrapper supports it.

## Compose payloads (RouteMsg / ReverseRouteMsg)

The router expects `composeMsg` to be ABI-encoded structs:

- **Forward**: `abi.encode(RouteMsg)`
  - `finalDstEid`: destination EID for shares (second hop)
  - `finalTo`: bytes32 recipient on destination
  - `refundBsc`: EVM address on this chain to receive refunds on failures
  - `minAmountLD2`: min shares for second hop (0 = accept full amount)

- **Reverse**: `abi.encode(ReverseRouteMsg)`
  - `underlying`: underlying token address to receive after unwrapping
  - `finalDstEid`: final destination EID for underlying (second hop); if equals `chainEid`, deliver locally
  - `finalTo`: bytes32 recipient; if delivering locally, it must encode an EVM address
  - `refundBsc`: EVM address on this chain to receive refunds on failures
  - `unwrapBps`: unwrap fraction in basis points (1..10000)
  - `minAmountLD2`: min underlying for second hop (0 = accept full amount)
  - `extraOptions2`: LayerZero options for the second hop
  - `composeMsg2`: compose payload for the second hop (optional)

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Installation

```bash
git clone https://github.com/dstockofficial/dstock-peripheral.git
cd dstock-peripheral
forge install
```

## Usage

### Compile

```bash
forge build
```

### Test

```bash
forge test
```

If your environment blocks Foundry's network calls (or you hit `OpenChainClient` issues), use:

```bash
forge test --offline
```

### Deploy

#### Deploy DStockComposerRouter (UUPS implementation + proxy)

```bash
ADMIN_PK=<deployer_private_key> \
ENDPOINT_ADDRESS=<layerzero_endpoint_v2_address> \
CHAIN_EID=<this_chain_eid> \
OWNER_ADDRESS=<router_owner_address> \
WRAPPER_ADDRESS=<dstock_wrapper_address_optional> \
SHARE_ADAPTER_ADDRESS=<shares_oft_adapter_address_optional> \
UNDERLYING_ADDRESS=<underlying_token_address_optional> \
forge script script/DeployComposerRouterProxy.s.sol:DeployComposerRouterProxy \
  --rpc-url <your_rpc_url> \
  --broadcast \
  --verify
```

After deploying, you can register more routes by calling `setRouteConfig(underlying, wrapper, shareAdapter)` as owner.
