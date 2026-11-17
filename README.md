# ushMON, the unstaking shMON vault

An ERC-4626 vault whose shares (ushMON) are denominated in shMON. An operator (the vault's exit desk) sends the vault's
shMON into shMonad's slow unstake (20 to 28 hours) and completes it; the MON that comes back is held as WMON. A holder
redeems ushMON for WMON at shMonad's redemption rate with `redeemForWmon`, inside the same Euler EVC batch that repays a
WMON loan. The vault runs the EVC account status checks that Euler's collateral vaults run, so a WMON vault can accept
ushMON as collateral and liquidate it.

Only the operator can receive shares (`maxDeposit` and `maxMint` are zero for any other receiver), so no outsider can
take matured WMON ahead of the desk. The desk's EulerSwap pool deposits a seller's shMON with the desk as receiver.

## Layout

- `src/UnstakingShMonVault.sol`, the vault.
- `script/Deploy.s.sol`, deploys one vault from the `EVC`, `SHMON`, `WMON` and `OPERATOR` env values.
- `test/UnstakingShMonVault.t.sol`, unit tests against a mock that burns shMON as live shMonad does.
- `test/UnstakingShMonVault.fork.t.sol`, the whole cycle against live shMonad on a fork of Monad.
- `lib/`, OpenZeppelin Contracts v5.2.0, Ethereum Vault Connector v1.0.1, forge-std.

## Tests

    forge test                                              # unit tests; the fork tests skip without an RPC
    MONAD_RPC_URL=<monad rpc> forge test -vv                # plus the fork tests against live shMonad

The fork test matures an unstake by writing shMonad's epoch (storage slot 18, low 64 bits), since a fork cannot crank.

## History

- v1 (2026-11-06): deployed for the shMON vaults' exit desks. Audited 2026-11-15; issues 1 to 11 filed 2026-11-16.
- v2 (2026-11-16): shares only to the operator (issue 1); `maxWithdraw`, `maxRedeem` and the new `maxRedeemForWmon`
  report what can actually leave (issue 2); `completeUnstake` wraps every wei of MON the vault holds (issue 3); no
  approval to the unstaker, a live-shaped mock and a fork test (issue 4); `startUnstake` clamps to the shMON held
  (issue 7); `completeUnstake` swallows shMonad's nothing-matured refusal (issue 8); `RedeemedForWmon` (issue 11).
  Issues 5, 6, 9 and 10 were closed with reasoning after study and tests (`test/UnstakingShMonVault.donation.t.sol`).
- v3 (2026-11-17, Root: "one ushMON"): one vault serves several exit desks. The constructor takes a list of operators;
  each operator's unstakes sit on its own ledger (`ledgerOf`), and `completeUnstake` credits the MON that comes back
  to the operator whose entries it pays (`wmonCredit`), so one desk can never redeem WMON another desk's unstake
  produced. MON or WMON that reaches the vault outside a ledger entry is a shared pot every holder draws pro rata
  (`sharedWmon`). `redeemForWmon` pays at most `wmonRedeemable(owner)`. Shares stay one pot, priced pro rata, so a
  desk holding shMON earns a little of the yield the other desk's unstaking MON does not (about 3 bps a day on the
  unstaking part at today's rate).

## Deployed on Monad

v3, deployed 2026-11-17 by `ag-euler/contracts/shmon-cluster-monad/deploy.sh desks`: one vault for both exit desks. The
cluster's router `0x99f7105CAC565Ac830cf2d66527FBb06dD322C32` resolves it to shMON and the WMON vault
`0xE4522663752AC47516e39aD11d3780a116850eaf` lends 93% against it and liquidates at 95%. Verified on Monadscan.

| vault | address | operators (exit desks) |
| --- | --- | --- |
| ushMON v3 | `0x37e07473F1F62CB071Db57440e242b320614A0ce` | `0x02Df7fb3b4535361EE10C391e3bDDAEe9001c770` (Delta One), `0xF460C4C68704Da32Ba3cefC2feEcaA3C3f3d6CdE` (Delta Neutral) |

Replaced, now empty: v2 `0xC8f5023512c0618B754e03d675E3626a4A760092` and `0xa2F34235e4C3c0706B2d5B9170F924446b1Df664`
(2026-11-16, one per desk); v1 `0xa44220Ee57Cb879bd842a24696Df06e398601d8F` and `0x066E1eb375369A00e324cF18Eb014B9AB0507690`
(open deposit); `0x59f7f897322D5FdEFCa38beB78137559eD985F80` and `0xc0CA1086131046766956bBD030fe9595Cc8204a1` on the older
eWMON-14 setup.

## Build

    git clone --recurse-submodules <this repo>
    forge build
