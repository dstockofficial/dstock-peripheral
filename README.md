# DStock Peripheral

Peripheral contracts for the DStock ecosystem, providing LayerZero-integrated bridge and router functionality for cross-chain token operations.

## Overview

This repository contains contracts that enable:
- **One-click wrap and bridge**: Wrap underlying tokens and bridge them to destination chains in a single transaction
- **Automatic unwrapping**: Composed messages trigger automatic unwrapping of dStock tokens upon arrival at destination

## Contracts

- **DStockRouter**: One-click wrap and bridge functionality (BSC → HyperEVM)
- **DStockUnwrapComposer**: LayerZero compose handler for automatic unwrapping on destination chain

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

#### Deploy Router (Source Chain - BSC)

```bash
ADMIN_PK=<deployer_private_key> \
WRAPPER_ADDRESS=<dstock_wrapper_address> \
OFT_ADAPTER_ADDRESS=<layerzero_oft_adapter_address> \
forge script script/DeployRouter.s.sol:DeployRouter \
  --rpc-url <your_rpc_url> \
  --broadcast \
  --verify
```

#### Deploy Unwrap Composer (Destination Chain - HyperEVM)

```bash
ADMIN_PK=<deployer_private_key> \
WRAPPER_ADDRESS=<dstock_wrapper_address> \
UNDERLYING_ADDRESS=<underlying_token_address> \
OFT_ADAPTER_ADDRESS=<layerzero_oft_adapter_address> \
forge script script/DeployUnwrapComposer.s.sol:DeployUnwrapComposer \
  --rpc-url <your_rpc_url> \
  --broadcast \
  --verify
```

## Documentation

For detailed documentation, see [.local/PROJECT.md](.local/PROJECT.md)
