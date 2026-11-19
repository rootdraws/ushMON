// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {UnstakingShMonVault} from "../src/UnstakingShMonVault.sol";

/// @notice shMON stand-in: an ERC20 at a fixed 1.6 MON rate that the unstaker can burn, as shMonad burns the caller's
contract MockShMon is ERC20("shMON", "shMON") {
    address public unstaker;

    function setUnstaker(address u) external {
        unstaker = u;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function burn(address from, uint256 a) external {
        require(msg.sender == unstaker, "only unstaker");
        _burn(from, a);
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return (shares * 16) / 10;
    }
}

contract MockWmon is ERC20("WMON", "WMON") {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @notice shMonad's slow unstake with epochs the test moves by hand
contract MockUnstaker {
    struct UnstakeRequest {
        uint128 amountMon;
        uint64 completionEpoch;
    }

    MockShMon public immutable shMon;
    uint64 public epoch = 10;
    mapping(address => UnstakeRequest[]) internal requests;

    constructor(MockShMon s) {
        shMon = s;
    }

    receive() external payable {}

    function setEpoch(uint64 e) external {
        epoch = e;
    }

    function getInternalEpoch() external view returns (uint64) {
        return epoch;
    }

    function requestUnstake(uint256 shares) external returns (uint64 completionEpoch) {
        shMon.burn(msg.sender, shares);
        completionEpoch = epoch + 2;
        requests[msg.sender].push(UnstakeRequest(uint128(shMon.convertToAssets(shares)), completionEpoch));
    }

    function getUnstakeRequests(address a) external view returns (UnstakeRequest[] memory) {
        return requests[a];
    }

    function completeUnstake() external {
        UnstakeRequest[] storage r = requests[msg.sender];
        uint256 paid;
        uint256 i = 0;
        while (i < r.length) {
            if (r[i].completionEpoch <= epoch) {
                paid += r[i].amountMon;
                r[i] = r[r.length - 1];
                r.pop();
            } else {
                i++;
            }
        }
        require(paid > 0, "nothing matured");
        (bool ok,) = msg.sender.call{value: paid}("");
        require(ok);
    }
}

/// @notice ushMON v4 (Root, 2026-11-18: "yes, build the ushMON fix"): the WMON behind seized shares follows them
contract UnstakingShMonVaultV4Test is Test {
    EthereumVaultConnector evc;
    MockShMon shmon;
    MockWmon wmon;
    MockUnstaker unstaker;
    UnstakingShMonVault vault;
    address deskA = address(0xA1);
    address deskB = address(0xB1);
    address liquidator = address(0x11);

    function setUp() public {
        evc = new EthereumVaultConnector();
        shmon = new MockShMon();
        wmon = new MockWmon();
        unstaker = new MockUnstaker(shmon);
        shmon.setUnstaker(address(unstaker));
        vm.deal(address(unstaker), 1e30);
        address[] memory ops = new address[](2);
        ops[0] = deskA;
        ops[1] = deskB;
        vault = new UnstakingShMonVault(address(evc), address(shmon), address(unstaker), address(wmon), ops);
        for (uint256 i = 0; i < 2; i++) {
            shmon.mint(ops[i], 1_000e18);
            vm.startPrank(ops[i]);
            shmon.approve(address(vault), type(uint256).max);
            vault.deposit(100e18, ops[i]);
            vault.startUnstake(100e18);
            vm.stopPrank();
        }
    }

    function _mature() internal {
        unstaker.setEpoch(20);
        vault.completeUnstake();
    }

    function test_seizerRedeemsTheWmonBehindItsShares() public {
        uint256 half = vault.balanceOf(deskA) / 2;
        vm.prank(deskA);
        vault.transfer(liquidator, half);
        _mature();
        uint256 owed = vault.convertToAssets(half) * 16 / 10;
        assertApproxEqAbs(vault.wmonRedeemable(liquidator), owed, 1e6, "the seizer can redeem its half");
        vm.prank(liquidator);
        uint256 got = vault.redeemForWmon(half, liquidator, liquidator);
        assertApproxEqAbs(got, 80e18, 1e6);
        assertEq(wmon.balanceOf(liquidator), got);
    }

    function test_creditAlreadyEarnedMovesWithTheShares() public {
        _mature();
        uint256 creditBefore = vault.wmonCredit(deskA);
        assertEq(creditBefore, 160e18);
        uint256 quarter = vault.balanceOf(deskA) / 4;
        vm.prank(deskA);
        vault.transfer(liquidator, quarter);
        assertApproxEqAbs(vault.wmonCredit(liquidator), 40e18, 1e6);
        assertApproxEqAbs(vault.wmonCredit(deskA), 120e18, 1e6);
        vm.prank(liquidator);
        vault.redeemForWmon(quarter, liquidator, liquidator);
        assertApproxEqAbs(wmon.balanceOf(liquidator), 40e18, 1e6);
    }

    function test_oneDeskStillCannotTakeTheOthersWmon() public {
        _mature();
        uint256 all = vault.balanceOf(deskA);
        vm.prank(deskA);
        vault.redeemForWmon(all, deskA, deskA);
        assertApproxEqAbs(wmon.balanceOf(deskA), 160e18, 1e6, "desk A gets its own unstake back");
        assertEq(vault.wmonCredit(deskB), 160e18, "desk B's credit is untouched");
    }

    function test_holdersPotIsReservedNotShared() public {
        uint256 half = vault.balanceOf(deskA) / 2;
        vm.prank(deskA);
        vault.transfer(liquidator, half);
        assertApproxEqAbs(vault.holderPending(), 80e18, 1e6);
        _mature();
        assertApproxEqAbs(vault.wmonCredit(address(1)), 80e18, 1e6, "the holders' pot holds the seizer's unstake");
        assertEq(vault.sharedWmon(), 0, "nothing leaks to the shared pot");
        vault.claimUnstaked(liquidator);
        assertApproxEqAbs(vault.wmonCredit(liquidator), 80e18, 1e6);
        assertEq(vault.holderPending(), 0);
    }

    function test_aSecondTransferCarriesItOnAgain() public {
        uint256 half = vault.balanceOf(deskA) / 2;
        vm.prank(deskA);
        vault.transfer(liquidator, half);
        address buyer = address(0x22);
        vm.prank(liquidator);
        vault.transfer(buyer, half / 2);
        _mature();
        vm.prank(buyer);
        uint256 got = vault.redeemForWmon(half / 2, buyer, buyer);
        assertApproxEqAbs(got, 40e18, 1e6);
    }

    function test_manyDustHoldersDoNotBurdenCompleteUnstake() public {
        uint256 half = vault.balanceOf(deskA) / 2;
        vm.prank(deskA);
        vault.transfer(liquidator, half);
        for (uint256 i = 0; i < 200; i++) {
            vm.prank(liquidator);
            vault.transfer(address(uint160(0x1000 + i)), 1e6);
        }
        unstaker.setEpoch(20);
        uint256 g = gasleft();
        vault.completeUnstake();
        assertLt(g - gasleft(), 400_000, "completeUnstake does not walk the holders");
        assertApproxEqAbs(vault.wmonCredit(deskA) + vault.wmonCredit(deskB), 240e18, 1e6, "the desks are paid first");
    }

    function test_onlyOperatorsGetNewSharesAndStartUnstakes() public {
        shmon.mint(liquidator, 10e18);
        vm.startPrank(liquidator);
        shmon.approve(address(vault), type(uint256).max);
        assertEq(vault.maxDeposit(liquidator), 0);
        vm.expectRevert(UnstakingShMonVault.NotOperator.selector);
        vault.startUnstake(1);
        vm.stopPrank();
    }
}
