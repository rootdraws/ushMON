# ushMON, the unstaking shMON vault

ushMON lets the shMON vaults' exit desks borrow WMON against shMON that is still unstaking. One vault serves both desks.

## How it works

- ushMON is an ERC-4626 vault. Its shares are counted in shMON.
- An exit desk deposits shMON and gets shares, which it uses as Euler collateral.
- The desk sends the shMON into shMonad's slow unstake, which takes 18 to 22 hours.
- When the unstake finishes, the MON comes back and the vault holds it as WMON.
- The desk redeems its shares for that WMON with `redeemForWmon`, and repays its WMON loan in the same Euler batch.

The vault runs the same account checks as Euler's own collateral vaults, so a WMON vault can lend against ushMON and
liquidate it.

## How the desks share it

- Each desk's unstakes and returned WMON are kept on its own ledger, so one desk never takes the other's WMON.
- When shares move, for example to a liquidator, the WMON and pending unstakes behind them move too. The new holder can
  redeem what it took.
- WMON that reaches the vault any other way is shared by every holder in proportion to its shares.
- Only a desk can receive new shares or start an unstake. A deposit naming anyone else as receiver is refused.

## Deployed on Monad

| Vault | Operators, the exit desks |
| --- | --- |
| `0xa753E24B0986567EDAd75f784664Ec11336f8C5e` | `0x02Df7fb3b4535361EE10C391e3bDDAEe9001c770` (Delta One), `0xF460C4C68704Da32Ba3cefC2feEcaA3C3f3d6CdE` (Delta Neutral) |

The cluster's router `0x99f7105CAC565Ac830cf2d66527FBb06dD322C32` prices ushMON as shMON. The WMON vault
`0xE4522663752AC47516e39aD11d3780a116850eaf` lends 93% against it and liquidates at 95%. The deployed code matches this
source, apart from constructor values and metadata.

## Layout

- `src/UnstakingShMonVault.sol`: the vault.
- `script/Deploy.s.sol`: deploys a vault from the `EVC`, `SHMON`, `WMON` and `OPERATORS` env values. `OPERATORS` is a
  comma-separated list of exit desks.
- `test/UnstakingShMonVault.t.sol`: unit tests against a mock that burns shMON as live shMonad does.
- `test/UnstakingShMonVaultV4.t.sol`: shares carrying their WMON, and two desks on one vault.
- `test/UnstakingShMonVault.donation.t.sol`: direct transfers to the vault, a 60-case grid and two fuzz runs.
- `test/UnstakingShMonVault.fork.t.sol`: the whole cycle against live shMonad on a fork of Monad.
- `lib/`: OpenZeppelin Contracts v5.2.0, Ethereum Vault Connector v1.0.1 and forge-std.

## Tests

    forge test                                  # unit tests; the fork tests skip without an RPC
    MONAD_RPC_URL=<monad rpc> forge test -vv    # adds the fork tests against live shMonad

All 28 pass. The fork test finishes an unstake by writing shMonad's epoch to storage slot 18, since a fork cannot
advance it.

## Security

An audit on 2026-11-15 found no high-severity issues. Eleven GitHub issues filed on 2026-11-16 are all closed: seven
fixed in the code, and four closed by design after study and tests.

## Build

    git clone --recurse-submodules <this repo>
    forge build
