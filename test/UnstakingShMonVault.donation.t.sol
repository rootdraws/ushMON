// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {UnstakingShMonVault} from "../src/UnstakingShMonVault.sol";
import {MockShMon, MockWmon, MockController} from "./UnstakingShMonVault.t.sol";

/// @notice Issue 10 study (Root, 2026-11-16: "run a handful of tests first, like 20-50 tests. See what happens under
///         different conditions."): tokens sent straight to the vault move its share price at once because totalAssets
///         reads balances. A grid of 60 cases (3 tokens × 5 sizes × 4 moments) and two fuzz runs check, in every case:
///         the donation is counted in full and no more; it creates no shares for the donor; the share price never falls;
///         the holders gain exactly the donation, pro rata; a deposit after a donation is never short-changed (the
///         1e6 virtual offset blunts the first-deposit trick); and the desk can take everything out afterwards.
contract UnstakingShMonVaultDonationTest is Test {
    uint256 constant WAIT = 1 days;
    uint256 constant X = 1_000e18; // the desk's deposit
    uint256 constant RATE = 1.5e18;

    EthereumVaultConnector evc;
    MockShMon shMon;
    MockWmon wmon;
    UnstakingShMonVault vault;
    address desk = makeAddr("desk");
    address donor = makeAddr("donor");
    address liquidator = makeAddr("liquidator");

    function setUp() public {
        evc = new EthereumVaultConnector();
        shMon = new MockShMon(WAIT);
        vm.deal(address(shMon), 1e30);
        wmon = new MockWmon();
        vault = new UnstakingShMonVault(address(evc), address(shMon), address(shMon), address(wmon), desk);
        shMon.mint(desk, 100 * X);
        shMon.mint(donor, 100_000 * X);
        vm.deal(donor, 1e30);
        vm.prank(desk);
        shMon.approve(address(vault), type(uint256).max);
        vm.prank(donor);
        wmon.deposit{value: 1_000 * X}();
    }

    // ---- helpers

    function _shmonUnits(uint8 token, uint256 amount) internal view returns (uint256) {
        return token == 0 ? amount : amount * 1e18 / shMon.rate();
    }

    /// @dev the vault's assets in shMON units as totalAssets counts them: shMON held, plus MON pending and WMON held at the rate
    function _assets() internal view returns (uint256) {
        return vault.totalAssets();
    }

    function _donate(uint8 token, uint256 amount) internal {
        if (token == 0) {
            vm.prank(donor);
            shMon.transfer(address(vault), amount);
        } else if (token == 1) {
            vm.prank(donor);
            wmon.transfer(address(vault), amount);
        } else {
            vm.prank(donor);
            (bool ok,) = address(vault).call{value: amount}("");
            require(ok);
        }
    }

    /// @dev puts the vault at one of four moments: 0 empty, 1 deposited, 2 half in the unstake, 3 completed (WMON held),
    ///      plus a liquidator holding 10% of the shares in moments 2 and 3
    function _moment(uint8 m) internal returns (uint256 deskShares) {
        if (m == 0) return 0;
        vm.prank(desk);
        deskShares = vault.deposit(X, desk);
        if (m >= 2) {
            vm.prank(desk);
            vault.startUnstake(X / 2);
            vm.prank(desk);
            vault.transfer(liquidator, deskShares / 10); // a seized share
            deskShares -= deskShares / 10;
        }
        if (m == 3) {
            vm.warp(block.timestamp + WAIT);
            vault.completeUnstake();
        }
    }

    function _claim(address who) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(who));
    }

    // ---- the grid

    function test_donationGrid() public {
        uint256[5] memory sizes = [uint256(1), 1e12, X / 100, X, 10 * X]; // 1 wei, dust, 1%, 100%, 1000% of the desk's deposit
        string[3] memory names = ["shMON", "WMON", "MON"];
        uint256 n;
        for (uint8 m = 0; m < 4; m++) {
            for (uint8 t = 0; t < 3; t++) {
                for (uint8 s = 0; s < 5; s++) {
                    uint256 snap = vm.snapshotState();
                    _case(m, t, sizes[s], names[t]);
                    vm.revertToState(snap);
                    n++;
                }
            }
        }
        assertEq(n, 60);
    }

    struct Before {
        uint256 assets;
        uint256 price;
        uint256 desk;
        uint256 liq;
        uint256 supply;
        uint256 deskShares;
    }

    function _case(uint8 m, uint8 t, uint256 amount, string memory name) internal {
        Before memory b;
        b.deskShares = _moment(m);
        b.assets = _assets();
        b.price = vault.convertToAssets(1e18);
        b.desk = _claim(desk);
        b.liq = _claim(liquidator);
        b.supply = vault.totalSupply();
        _donate(t, amount);
        if (t == 2) vault.completeUnstake(); // native MON counts once wrapped (issue 3 and 8: a no-op completion wraps it)
        _checkDonation(b, _shmonUnits(t, amount));
        _checkDepositAndExit(b);
        console2.log(string.concat("moment ", vm.toString(m), " ", name, " ", vm.toString(amount), " wei: price ", vm.toString(b.price), " -> ", vm.toString(vault.convertToAssets(1e18))));
    }

    function _checkDonation(Before memory b, uint256 added) internal view {
        // 1. counted in full and no more (1 wei of rounding on the MON side)
        assertApproxEqAbs(_assets(), b.assets + added, 1, "the donation is counted once");
        // 2. no shares for the donor, no new shares at all
        assertEq(vault.balanceOf(donor), 0);
        assertEq(vault.totalSupply(), b.supply);
        // 3. the share price never falls
        assertGe(vault.convertToAssets(1e18), b.price, "price never falls");
        // 4. the holders gain the donation pro rata, and nobody else; the virtual 1e6 shares absorb a dust share of it
        uint256 gained = (_claim(desk) - b.desk) + (_claim(liquidator) - b.liq);
        if (b.supply == 0) {
            assertEq(gained, 0, "no holders yet: nobody gains until the desk deposits");
        } else {
            uint256 virtualShare = added * 1e6 / (b.supply + 1e6);
            assertApproxEqAbs(gained, added - virtualShare, 2, "holders gain the donation less the virtual dust");
            if (vault.balanceOf(liquidator) > 0) {
                assertApproxEqRel(_claim(liquidator) - b.liq, (added - virtualShare) / 10, 0.01e18, "a liquidator's tenth");
            }
        }
    }

    function _checkDepositAndExit(Before memory) internal {
        // 5. a deposit after the donation loses at most one share's worth to rounding: a donation of D before any
        //    shares exist makes one share worth about D / 1e6 (the virtual offset), so a 10,000 shMON gift makes the
        //    share grain 0.01 shMON. The desk puts in X more and can claim at least X less that grain.
        uint256 grain = (vault.totalAssets() + 1e6) / (vault.totalSupply() + 1e6) + 1;
        uint256 claimBefore = _claim(desk);
        vm.prank(desk);
        uint256 minted = vault.deposit(X, desk);
        assertGe(_claim(desk) + grain, claimBefore + X, "a deposit after a donation loses at most one share's worth");
        assertGt(minted, 0, "a deposit after any donation still mints");
        // 6. the desk can take everything out: shMON held by withdraw, WMON held by redeemForWmon
        if (vault.maxWithdraw(desk) > 0) {
            uint256 w = vault.maxWithdraw(desk);
            vm.prank(desk);
            vault.withdraw(w, desk, desk);
        }
        if (vault.maxRedeemForWmon(desk) > 0) {
            uint256 r = vault.maxRedeemForWmon(desk);
            vm.prank(desk);
            vault.redeemForWmon(r, desk, desk);
        }
    }

    // ---- fuzz: any token, any size up to 1,000x the deposit, any moment

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_donationIsCountedOnceAndNeverMintsOrLowersPrice(uint8 token, uint96 amount, uint8 moment) public {
        token = uint8(bound(token, 0, 2));
        moment = uint8(bound(moment, 0, 3));
        uint256 amt = bound(uint256(amount), 1, 1_000 * X);
        _moment(moment);
        uint256 assetsBefore = _assets();
        uint256 priceBefore = vault.convertToAssets(1e18);
        uint256 supplyBefore = vault.totalSupply();
        _donate(token, amt);
        if (token == 2) vault.completeUnstake();
        assertApproxEqAbs(_assets(), assetsBefore + _shmonUnits(token, amt), 1);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.balanceOf(donor), 0);
        assertGe(vault.convertToAssets(1e18), priceBefore);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_firstDepositAfterDonationKeepsItsValue(uint96 donation, uint96 deposit) public {
        uint256 d = bound(uint256(donation), 1, 10_000 * X);
        uint256 x = bound(uint256(deposit), 1e15, 10 * X); // from 0.001 shMON up
        vm.prank(donor);
        shMon.transfer(address(vault), d); // the classic first-deposit trick: inflate before the first deposit
        uint256 grain = (d + 1e6) / 1e6 + 1; // one share's worth after the gift
        vm.prank(desk);
        uint256 minted = vault.deposit(x, desk);
        if (x >= grain) assertGt(minted, 0, "a deposit of at least one share's worth mints");
        // the desk's claim is its deposit less at most one share's worth; the donor's shMON went to the desk and the
        // virtual shares, never back to the donor
        assertGe(vault.convertToAssets(minted) + grain, x, "loses at most one share's worth");
        assertEq(vault.balanceOf(donor), 0);
    }
}
