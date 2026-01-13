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
