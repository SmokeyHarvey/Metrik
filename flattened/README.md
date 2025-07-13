# Flattened Smart Contracts

This directory contains flattened versions of all smart contracts for the DeFi Credit Protocol.

## Contract Files

| Contract | Size | Lines | Description |
|----------|------|-------|-------------|
| `MockERC20_flattened.sol` | 25KB | 763 | Mock ERC20 token implementation |
| `InvoiceNFT_flattened.sol` | 150KB | 4,322 | Invoice NFT contract with verification |
| `Staking_flattened.sol` | 59KB | 1,659 | METRIK token staking with tier system |
| `LendingPool_flattened.sol` | 235KB | 6,670 | Main lending pool with tranche system |
| `BorrowRegistry_flattened.sol` | 6.2KB | 203 | Borrow history and default tracking |

## Total Size
- **Total Size**: 968KB
- **Total Lines**: 13,617 lines

## Usage
These flattened contracts can be deployed directly on any EVM-compatible blockchain without external dependencies. All OpenZeppelin imports and dependencies have been inlined.

## Deployment Order
1. MockERC20 (for METRIK and USDC tokens)
2. InvoiceNFT
3. Staking
4. LendingPool
5. BorrowRegistry

## Notes
- All contracts are flattened and self-contained
- OpenZeppelin dependencies are inlined
- Ready for deployment on any EVM chain
- Includes all necessary interfaces and libraries 