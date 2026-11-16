# ushMON, the unstaking shMON vault

An ERC-4626 vault whose shares (ushMON) are denominated in shMON. An operator sends the vault's shMON into
shMonad's slow unstake (20 to 28 hours) and completes it; the MON that comes back is held as WMON. A holder
redeems ushMON for WMON at shMonad's redemption rate with `redeemForWmon`, inside the same Euler EVC batch that
repays a WMON loan. The vault runs the EVC account status checks that Euler's collateral vaults run, so a WMON
vault can accept ushMON as collateral and liquidate it.

## Layout

- `src/UnstakingShMonVault.sol`, the vault.
- `script/Deploy.s.sol`, deploys one vault from the `EVC`, `SHMON`, `WMON` and `OPERATOR` env values.
- `test/UnstakeStandIn.sol`, a fork-only stand-in for shMonad's unstake (anvil cannot advance shMonad's epoch).
- `lib/`, OpenZeppelin Contracts v5.2.0, Ethereum Vault Connector v1.0.1, forge-std.

## Deployed on Monad (2026-11-06)

- USDC vault's exit desk: `0x59f7f897322D5FdEFCa38beB78137559eD985F80`
- USDT0 vault's exit desk: `0xc0CA1086131046766956bBD030fe9595Cc8204a1`
- Collateral on the WMON vault `0xfE26b4EE9e7000e06B7Cb2fc614A4526e845e702` at 97% borrow LTV, 98% liquidation.

Not yet audited.

## Build

    git clone --recurse-submodules <this repo>
    forge build
