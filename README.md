# Smart Contracts

TypeScript Hardhat 3 project for developing, testing, and deploying EVM-compatible smart contracts.

## Setup

```bash
npm install
```

## Common Commands

```bash
npm run build
npm test
npm run test:ts
npm run node
npm run deploy:counter
```

## Project Layout

- `contracts/` contains Solidity contracts.
- `test/` contains TypeScript tests using `node:test` and Viem.
- `scripts/` contains deployment and automation scripts.
- `hardhat.config.ts` contains compiler, plugin, and network configuration.

## Testnet Configuration

Set config variables before deploying to a live network:

```bash
npx hardhat vars set SEPOLIA_RPC_URL
npx hardhat vars set SEPOLIA_PRIVATE_KEY
```

Then run:

```bash
npm run deploy:counter -- --network sepolia
```
