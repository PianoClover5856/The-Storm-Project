# Storm (STORM)

Storm is an ERC-20 meme coin built with a focus on transparent, holder-protective tokenomics — fixed supply cap, launch-phase anti-whale and anti-bot protections, and a timelock on every sensitive owner control so changes are never silent.

## Overview

- **Name:** Storm
- **Symbol:** STORM
- **Decimals:** 18
- **Max Supply:** 1,000,000,000 STORM (hard cap, enforced on-chain)
- **Initial Mint:** 500,000,000 STORM to the deployer at launch
- **Standard:** OpenZeppelin ERC20 + ERC20Burnable + Ownable

## Tokenomics

| Mechanism | Detail |
|---|---|
| Supply cap | 1B STORM max, enforced by `mint()` — cannot be exceeded |
| Initial mint | 50% of max supply minted at deploy; remainder mintable later, only up to the cap |
| Buy/sell tax | 5% total by default (2% burned, 3% to treasury), adjustable up to a 10% hard cap |
| Tax scope | Applies only to transfers touching a registered AMM pair (real buys/sells) — wallet-to-wallet transfers are tax-free |

## Launch Protections

- **Anti-whale limits** — max transaction and max wallet size, default 1% of max supply each. Limits can be raised but never lowered below a 0.5% floor, so they can never be tightened into a freeze.
- **Same-block anti-bot guard** — blocks a wallet from trading against the pair more than once in a single block, closing off the standard sniper/sandwich-bot pattern at launch.
- Both protections are owner-toggleable for post-launch relaxation, and both support per-address exclusions for routers, market makers, and other legitimate contracts.

## Timelock

Every sensitive owner action — minting, tax changes, treasury wallet updates, AMM pair registration, fee/limit exclusions, and ownership transfer — requires a two-step, publicly visible process:

1. **Queue** — owner calls `queueAction()` with a hash of the exact function call. This emits an `ActionQueued` event with the timestamp the action becomes executable.
2. **Execute** — after a **2-day delay**, the owner repeats the identical call, which is checked against the queued hash and executed.

This means holders always get advance, on-chain warning before any parameter that affects them changes. `renounceOwnership()` is the one exception and remains immediate, since giving up ownership only ever reduces the contract's power.

## Contract

The full implementation is in [`Storm.sol`](./Storm.sol).

Built on [OpenZeppelin Contracts v5](https://github.com/OpenZeppelin/openzeppelin-contracts):

```bash
npm install @openzeppelin/contracts
```

## Deployment

The constructor requires:

```solidity
constructor(address _treasuryWallet, address _initialOwner)
```

After deployment:

1. Create your liquidity pool (e.g. on Uniswap) and lock the LP tokens.
2. Register the pool address via the timelocked `setAmmPair()` flow so buy/sell tax and anti-bot protections activate.
3. Exclude any additional trusted addresses (marketing wallet, vesting contracts, market makers) from tax/limits/anti-bot as needed.
4. When ready to decentralize fully, call `renounceOwnership()`.

## Status

⚠️ This contract has not yet been tested, audited, or deployed to any network. Do not use in production until it has a test suite and, ideally, an independent audit.

## License

MIT
