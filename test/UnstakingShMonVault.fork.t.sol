// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {UnstakingShMonVault, IUnstaker} from "../src/UnstakingShMonVault.sol";

interface IShMonadLive {
    function deposit(uint256 assets, address receiver) external payable returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function getUnstakeRequests(address account) external view returns (IUnstaker.UnstakeRequest[] memory);
}

/// @notice The whole cycle against live shMonad on a fork of Monad (issue 4): deposit, startUnstake (shMonad burns the
///         vault's shMON, no approval), pendingMon and totalAssets, maturity by moving shMonad's epoch (storage slot 18,
///         low 64 bits; a fork cannot crank), completeUnstake, redeemForWmon, and the issue-1 attack stopping at the deposit.
///         Skips without MONAD_RPC_URL:  MONAD_RPC_URL=<rpc> forge test --match-path test/UnstakingShMonVault.fork.t.sol -vv
contract UnstakingShMonVaultForkTest is Test {
    address constant EVC = 0x7a9324E8f270413fa2E458f5831226d99C7477CD;
    address constant SHMON = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    uint256 constant EPOCH_SLOT = 18;

    UnstakingShMonVault vault;
    address operator = makeAddr("operator");
    address outsider = makeAddr("outsider");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        vault = new UnstakingShMonVault(EVC, SHMON, SHMON, WMON, operator);
        vm.deal(operator, 1_000 ether);
        vm.deal(outsider, 1_000 ether);
    }

    function _stake(address who, uint256 mon) internal returns (uint256 shares) {
        vm.prank(who);
        shares = IShMonadLive(SHMON).deposit{value: mon}(mon, who);
        vm.prank(who);
        IERC20(SHMON).approve(address(vault), type(uint256).max);
    }

    function _mature() internal {
        IUnstaker.UnstakeRequest[] memory r = IShMonadLive(SHMON).getUnstakeRequests(address(vault));
        uint64 target;
        for (uint256 i = 0; i < r.length; i++) if (r[i].completionEpoch > target) target = r[i].completionEpoch;
        bytes32 cur = vm.load(SHMON, bytes32(EPOCH_SLOT));
        bytes32 next = bytes32((uint256(cur) & ~uint256(type(uint64).max)) | uint256(target));
        vm.store(SHMON, bytes32(EPOCH_SLOT), next);
    }

    function test_cycleAgainstLiveShMonad() public {
        if (!forked) return;
        assertEq(IERC20(SHMON).allowance(address(vault), SHMON), 0, "no approval to shMonad");
        uint256 shares = _stake(operator, 100 ether);
        vm.prank(operator);
        uint256 ushShares = vault.deposit(shares, operator);
        assertEq(vault.totalAssets(), shares);
        assertEq(vault.maxRedeem(operator), ushShares);

        vm.prank(operator);
        vault.startUnstake(shares);
        assertEq(IERC20(SHMON).balanceOf(address(vault)), 0, "shMonad burned the vault's shMON");
        uint256 pending = vault.pendingMon();
        assertGt(pending, 0);
        uint256 expectedMon = IShMonadLive(SHMON).convertToAssets(shares);
        assertApproxEqRel(pending, expectedMon, 1e15, "the request holds the shMON's MON value");
        assertApproxEqRel(vault.totalAssets(), shares, 1e15, "assets unchanged while in the unstake");
        assertEq(vault.maxRedeem(operator), 0, "nothing to withdraw while in the unstake");

        _mature();
        uint256 mon = vault.completeUnstake();
        assertEq(mon, pending);
        assertEq(IERC20(WMON).balanceOf(address(vault)), pending);
        assertEq(vault.pendingMon(), 0);

        // the issue-1 attack: an outsider cannot mint a claim on the WMON
        uint256 oShares = _stake(outsider, 10 ether);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, outsider, oShares, 0));
        vault.deposit(oShares, outsider);

        uint256 m = vault.maxRedeemForWmon(operator);
        assertEq(m, ushShares);
        vm.prank(operator);
        uint256 out = vault.redeemForWmon(m, operator, operator);
        assertEq(out, IERC20(WMON).balanceOf(operator));
        assertLt(IERC20(WMON).balanceOf(address(vault)), 100, "a few wei of rounding at most, on about 165e18");
        assertEq(vault.totalSupply(), 0);
    }

    function test_completeUnstakeWithNothingMaturedIsSwallowed() public {
        if (!forked) return;
        uint256 shares = _stake(operator, 10 ether);
        vm.prank(operator);
        vault.deposit(shares, operator);
        vm.prank(operator);
        vault.startUnstake(shares);
        // live shMonad reverts with nothing matured (issue 4's table); the vault swallows it (issue 8) and returns 0
        assertEq(vault.completeUnstake(), 0);
        assertGt(vault.pendingMon(), 0, "the request is still pending");
    }
}
