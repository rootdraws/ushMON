// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {IVault} from "ethereum-vault-connector/interfaces/IVault.sol";
import {UnstakingShMonVault} from "../src/UnstakingShMonVault.sol";

/// @dev shMON stand-in shaped like live shMonad (issue 4): the token is also the unstaker, `requestUnstake` burns the
///      caller's shMON with no approval, `completeUnstake` reverts with nothing matured, and MON is paid from the
///      contract's own balance. Its MON value per share is set by the test; maturity is a timestamp in place of an epoch.
contract MockShMon is ERC20 {
    struct UnstakeRequest {
        uint128 amountMon;
        uint64 completionEpoch;
    }

    uint256 public rate = 1.5e18;
    uint256 public immutable waitSeconds;
    mapping(address => UnstakeRequest[]) internal requests;

    error NothingMatured();

    constructor(uint256 waitSeconds_) ERC20("shMON", "shMON") {
        waitSeconds = waitSeconds_;
    }

    receive() external payable {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * rate / 1e18;
    }

    function requestUnstake(uint256 shares) external returns (uint64 completionEpoch) {
        _burn(msg.sender, shares);
        completionEpoch = uint64(block.timestamp + waitSeconds);
        requests[msg.sender].push(UnstakeRequest(uint128(shares * rate / 1e18), completionEpoch));
    }

    function getUnstakeRequests(address account) external view returns (UnstakeRequest[] memory) {
        return requests[account];
    }

    /// @dev the mock's epoch is the clock: a request matures when its completionEpoch (a timestamp) has passed
    function getInternalEpoch() external view returns (uint64) {
        return uint64(block.timestamp);
    }

    function completeUnstake() external {
        UnstakeRequest[] storage r = requests[msg.sender];
        uint256 paid;
        uint256 i = 0;
        while (i < r.length) {
            if (r[i].completionEpoch <= block.timestamp) {
                paid += r[i].amountMon;
                r[i] = r[r.length - 1];
                r.pop();
            } else {
                i++;
            }
        }
        if (paid == 0) revert NothingMatured();
        (bool ok,) = msg.sender.call{value: paid}("");
        require(ok, "pay failed");
    }
}

contract MockWmon is ERC20 {
    constructor() ERC20("WMON", "WMON") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @dev a controller that accepts every account, so the EVC lets the test enable it
contract MockController is IVault {
    function disableController() external {}

    function checkAccountStatus(address, address[] calldata) external pure returns (bytes4) {
        return IVault.checkAccountStatus.selector;
    }

    function checkVaultStatus() external pure returns (bytes4) {
        return IVault.checkVaultStatus.selector;
    }
}

/// @dev one operator as the constructor's list
function _ops(address a) pure returns (address[] memory ops) {
    ops = new address[](1);
    ops[0] = a;
}

contract UnstakingShMonVaultTest is Test {
    uint256 constant WAIT = 1 days;
    uint256 constant DEPOSIT = 1_000e18;

    EthereumVaultConnector evc;
    MockShMon shMon;
    MockWmon wmon;
    MockController controller;
    UnstakingShMonVault vault;

    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address pool = makeAddr("pool");

    function setUp() public {
        evc = new EthereumVaultConnector();
        shMon = new MockShMon(WAIT);
        vm.deal(address(shMon), 1_000_000 ether);
        wmon = new MockWmon();
        controller = new MockController();
        vault = new UnstakingShMonVault(address(evc), address(shMon), address(shMon), address(wmon), _ops(operator));
        assertEq(shMon.allowance(address(vault), address(shMon)), 0, "no approval to the unstaker (issue 4)");

        shMon.mint(operator, 10 * DEPOSIT);
        shMon.mint(alice, 10 * DEPOSIT);
        shMon.mint(pool, 10 * DEPOSIT);
        vm.prank(operator);
        shMon.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        shMon.approve(address(vault), type(uint256).max);
        vm.prank(pool);
        shMon.approve(address(vault), type(uint256).max);
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        vm.prank(operator);
        shares = vault.deposit(amount, operator);
    }

    function _unstake(uint256 amount) internal {
        vm.prank(operator);
        vault.startUnstake(amount);
    }

    // ---- issue 1: shares only to the operator

    function test_depositByNonOperatorReverts() public {
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, DEPOSIT, 0));
        vault.deposit(DEPOSIT, alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, alice, DEPOSIT, 0));
        vault.mint(DEPOSIT, alice);
        vm.stopPrank();
    }

    function test_poolStyleDepositToOperatorFromAnotherCaller() public {
        assertEq(vault.maxDeposit(operator), type(uint256).max);
        assertEq(vault.maxMint(operator), type(uint256).max);
        vm.prank(pool);
        uint256 shares = vault.deposit(DEPOSIT, operator);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(operator), shares);
        assertEq(vault.balanceOf(pool), 0);
        assertEq(shMon.balanceOf(address(vault)), DEPOSIT);
    }

    /// @dev the three-call attack of issue 1: complete, deposit, redeem for WMON in one go. It now stops at the deposit.
    function test_issue1AttackRevertsAtDeposit() public {
        _deposit(DEPOSIT);
        _unstake(DEPOSIT);
        vm.warp(block.timestamp + WAIT);
        vm.startPrank(alice);
        vault.completeUnstake();
        assertEq(wmon.balanceOf(address(vault)), DEPOSIT * 1.5e18 / 1e18);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, DEPOSIT, 0));
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
        // the operator's settle finds all of the WMON
        uint256 m = vault.maxRedeemForWmon(operator);
        assertEq(m, vault.balanceOf(operator));
        vm.prank(operator);
        uint256 out = vault.redeemForWmon(m, operator, operator);
        assertEq(out, wmon.balanceOf(operator));
        assertLe(wmon.balanceOf(address(vault)), 1);
    }

    // ---- issue 2: max views report what can actually leave

    function test_maxWithdrawRedeemZeroWhileInUnstake() public {
        _deposit(DEPOSIT);
        _unstake(DEPOSIT);
        assertEq(shMon.balanceOf(address(vault)), 0);
        assertEq(vault.totalAssets(), DEPOSIT);
        assertEq(vault.maxWithdraw(operator), 0);
        assertEq(vault.maxRedeem(operator), 0);
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, operator, 1, 0));
        vault.withdraw(1, operator, operator);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, operator, 1e6, 0));
        vault.redeem(1e6, operator, operator);
        vm.stopPrank();
    }

    function test_maxWithdrawRedeemEqualClaimWhenHeld() public {
        uint256 shares = _deposit(DEPOSIT);
        assertEq(vault.maxRedeem(operator), shares);
        assertEq(vault.maxWithdraw(operator), vault.convertToAssets(shares));
        // half in the unstake: bounded by the half still held
        _unstake(DEPOSIT / 2);
        assertEq(vault.maxWithdraw(operator), DEPOSIT / 2);
        assertEq(vault.maxRedeem(operator), vault.convertToShares(DEPOSIT / 2));
        uint256 m = vault.maxRedeem(operator);
        vm.prank(operator);
        vault.redeem(m, operator, operator);
        assertLe(shMon.balanceOf(address(vault)), 1);
    }

    function test_maxViewsZeroWithController() public {
        uint256 shares = _deposit(DEPOSIT);
        vm.prank(operator);
        evc.enableController(operator, address(controller));
        assertEq(vault.maxWithdraw(operator), 0);
        assertEq(vault.maxRedeem(operator), 0);
        assertEq(vault.maxRedeemForWmon(operator), 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, operator, shares, 0));
        vault.redeem(shares, operator, operator);
    }

    function test_maxRedeemForWmonMatchesPayable() public {
        _deposit(DEPOSIT);
        _unstake(DEPOSIT / 2);
        assertEq(vault.maxRedeemForWmon(operator), 0);
        vm.warp(block.timestamp + WAIT);
        vault.completeUnstake();
        uint256[3] memory rates = [uint256(1.5e18), 1.7e18, 1.3e18];
        for (uint256 i = 0; i < rates.length; i++) {
            shMon.setRate(rates[i]);
            uint256 m = vault.maxRedeemForWmon(operator);
            assertGt(m, 0);
            assertLt(m, vault.balanceOf(operator));
            // the view floors four times (MON to shMON, shMON to shares, back, and to WMON), so it may sit a few wei
            // of shares under what the WMON pays; five shares over always exceeds it at these rates
            uint256 snap = vm.snapshotState();
            vm.startPrank(operator);
            vm.expectRevert(UnstakingShMonVault.InsufficientWmon.selector);
            vault.redeemForWmon(m + 5, operator, operator);
            uint256 out = vault.redeemForWmon(m, operator, operator);
            vm.stopPrank();
            assertEq(wmon.balanceOf(operator), out);
            assertLt(wmon.balanceOf(address(vault)), 3 * rates[i] / 1e18 + 3, "a few wei of WMON left at most");
            vm.revertToState(snap);
        }
    }

    // ---- issue 3: stray MON is wrapped and counted

    function test_completeUnstakeWrapsStrayMon() public {
        _deposit(DEPOSIT);
        uint256 before = vault.totalAssets();
        vm.deal(address(vault), 3 ether);
        assertEq(vault.totalAssets(), before, "stray MON is not counted until wrapped");
        // live shMonad refuses a completion with nothing matured; the vault swallows that (issue 8) and still wraps the stray
        uint256 mon = vault.completeUnstake();
        assertEq(mon, 3 ether, "the stray is wrapped with nothing matured");
        assertEq(address(vault).balance, 0);
        assertEq(vault.totalAssets(), before + 3 ether * 1e18 / 1.5e18, "the stray now counts for the holders");
        // a matured request plus a second stray wei: both wrapped
        _unstake(DEPOSIT / 4);
        vm.warp(block.timestamp + WAIT);
        vm.deal(address(vault), 1);
        mon = vault.completeUnstake();
        assertEq(mon, (DEPOSIT / 4) * 1.5e18 / 1e18 + 1, "the matured MON and the stray wei are both wrapped");
        assertEq(address(vault).balance, 0);
    }

    // ---- the cycle

    function test_happyPath() public {
        uint256 shares = _deposit(DEPOSIT);
        _unstake(DEPOSIT);
        assertEq(vault.pendingMon(), DEPOSIT * 1.5e18 / 1e18);
        vm.warp(block.timestamp + WAIT);
        uint256 mon = vault.completeUnstake();
        assertEq(mon, DEPOSIT * 1.5e18 / 1e18);
        assertEq(vault.pendingMon(), 0);
        assertEq(vault.maxRedeemForWmon(operator), shares);
        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakingShMonVault.RedeemedForWmon(operator, operator, operator, shares, mon); // issue 11
        vm.prank(operator);
        uint256 out = vault.redeemForWmon(shares, operator, operator);
        assertEq(out, mon);
        assertEq(wmon.balanceOf(operator), mon);
        assertEq(vault.totalSupply(), 0);
    }

    /// @dev issue 7: a wei leaves just before an exact "everything" request; the request still goes through for what is there
    function test_startUnstakeClampsToHeld() public {
        _deposit(DEPOSIT);
        vm.prank(operator);
        vault.withdraw(1, operator, operator);
        _unstake(DEPOSIT); // one wei more than the vault holds
        assertEq(shMon.balanceOf(address(vault)), 0);
        assertEq(vault.pendingMon(), (DEPOSIT - 1) * 1.5e18 / 1e18);
        _unstake(type(uint256).max); // nothing left: a no-op, not a revert
        assertEq(vault.pendingMon(), (DEPOSIT - 1) * 1.5e18 / 1e18);
    }

    /// @dev issue 8: with no request and no stray MON the call is a no-op that returns 0, and a batch around it survives
    function test_completeUnstakeNothingToDoIsNoOp() public {
        _deposit(DEPOSIT);
        assertEq(vault.completeUnstake(), 0);
        _unstake(DEPOSIT / 2);
        assertEq(vault.completeUnstake(), 0, "not matured yet: shMonad's refusal is swallowed");
        vm.warp(block.timestamp + WAIT);
        assertEq(vault.completeUnstake(), (DEPOSIT / 2) * 1.5e18 / 1e18);
    }

    function test_startUnstakeOnlyOperator() public {
        _deposit(DEPOSIT);
        vm.prank(alice);
        vm.expectRevert(UnstakingShMonVault.NotOperator.selector);
        vault.startUnstake(1);
    }

    // ---- v3: two operators on one vault, each with its own WMON

    address deskB = makeAddr("deskB");

    function _twoDesks() internal returns (UnstakingShMonVault v) {
        address[] memory ops = new address[](2);
        ops[0] = operator;
        ops[1] = deskB;
        v = new UnstakingShMonVault(address(evc), address(shMon), address(shMon), address(wmon), ops);
        shMon.mint(deskB, 10 * DEPOSIT);
        vm.prank(operator);
        shMon.approve(address(v), type(uint256).max);
        vm.prank(deskB);
        shMon.approve(address(v), type(uint256).max);
        assertEq(v.operators().length, 2);
        assertTrue(v.isOperator(operator) && v.isOperator(deskB));
        assertEq(v.maxDeposit(deskB), type(uint256).max);
    }

    /// @dev desk A unstakes; when its MON comes back, only A can redeem it, B's shares buy nothing until B's own lands
    function test_twoDesks_onlyTheUnstakerRedeemsItsWmon() public {
        UnstakingShMonVault v = _twoDesks();
        vm.prank(operator);
        uint256 sharesA = v.deposit(DEPOSIT, operator);
        vm.prank(deskB);
        uint256 sharesB = v.deposit(DEPOSIT, deskB);
        vm.prank(operator);
        v.startUnstake(DEPOSIT);
        assertEq(v.ledgerOf(operator).length, 1);
        assertEq(v.ledgerOf(deskB).length, 0);
        vm.warp(block.timestamp + WAIT);
        uint256 mon = v.completeUnstake();
        assertEq(mon, DEPOSIT * 1.5e18 / 1e18);
        assertEq(v.wmonCredit(operator), mon, "A's ledger entry became A's credit");
        assertEq(v.wmonCredit(deskB), 0);
        assertEq(v.sharedWmon(), 0, "nothing stray");
        assertEq(v.maxRedeemForWmon(deskB), 0, "B cannot touch A's WMON");
        vm.prank(deskB);
        vm.expectRevert(UnstakingShMonVault.InsufficientWmon.selector);
        v.redeemForWmon(1e18, deskB, deskB);
        uint256 m = v.maxRedeemForWmon(operator);
        assertApproxEqAbs(m, sharesA, 5, "A can redeem about all of its shares for WMON");
        vm.prank(operator);
        uint256 out = v.redeemForWmon(m, operator, operator);
        assertApproxEqAbs(out, mon, 10);
        assertEq(v.balanceOf(deskB), sharesB, "B's shares untouched");
        // B's shMON is still shMON: B can withdraw it
        assertEq(v.maxWithdraw(deskB), v.convertToAssets(sharesB));
    }

    /// @dev both unstake at different times: each is credited its own amount, oldest ledger entries first
    function test_twoDesks_creditsFollowEachLedger() public {
        UnstakingShMonVault v = _twoDesks();
        vm.prank(operator);
        v.deposit(DEPOSIT, operator);
        vm.prank(deskB);
        v.deposit(DEPOSIT, deskB);
        vm.prank(operator);
        v.startUnstake(DEPOSIT / 2);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(deskB);
        v.startUnstake(DEPOSIT);
        vm.warp(block.timestamp + WAIT - 1 hours);
        v.completeUnstake(); // only A's has matured
        assertEq(v.wmonCredit(operator), (DEPOSIT / 2) * 1.5e18 / 1e18);
        assertEq(v.wmonCredit(deskB), 0);
        assertEq(v.ledgerOf(deskB).length, 1, "B's still on its way");
        vm.warp(block.timestamp + 1 hours);
        v.completeUnstake();
        assertEq(v.wmonCredit(deskB), DEPOSIT * 1.5e18 / 1e18);
        assertEq(v.ledgerOf(deskB).length, 0);
        assertEq(v.creditTotal(), wmon.balanceOf(address(v)), "every WMON held is somebody's credit");
    }

    /// @dev stray MON and WMON sent straight in belong to every holder pro rata, operators and a liquidator alike
    function test_twoDesks_strayIsSharedProRata() public {
        UnstakingShMonVault v = _twoDesks();
        vm.prank(operator);
        uint256 sharesA = v.deposit(3 * DEPOSIT, operator);
        vm.prank(deskB);
        uint256 sharesB = v.deposit(DEPOSIT, deskB);
        vm.prank(operator);
        v.transfer(alice, sharesA / 3); // a liquidator seized a third of A's shares
        vm.deal(address(v), 4 ether);
        v.completeUnstake(); // nothing matured: the stray is wrapped and shared
        assertEq(v.wmonCredit(address(0)), 4 ether);
        assertEq(v.sharedWmon(), 4 ether);
        uint256 supply = v.totalSupply();
        assertEq(v.wmonRedeemable(deskB), 4 ether * sharesB / supply);
        assertEq(v.wmonRedeemable(alice), 4 ether * (sharesA / 3) / supply);
        // WMON sent straight in counts the same way, before any completeUnstake
        wmon.deposit{value: 2 ether}();
        wmon.transfer(address(v), 2 ether);
        assertEq(v.sharedWmon(), 6 ether);
        uint256 m = v.maxRedeemForWmon(alice);
        assertGt(m, 0);
        vm.prank(alice);
        uint256 out = v.redeemForWmon(m, alice, alice);
        assertApproxEqAbs(out, 6 ether * (sharesA / 3) / supply, 1e12, "the liquidator's share of the pot");
        assertEq(v.creditTotal() + v.sharedWmon() - v.wmonCredit(address(0)), wmon.balanceOf(address(v)), "books balance");
    }

    /// @dev a non-operator cannot start an unstake or get shares, as before
    function test_twoDesks_outsiderStillShutOut() public {
        UnstakingShMonVault v = _twoDesks();
        assertEq(v.maxDeposit(alice), 0);
        vm.prank(alice);
        vm.expectRevert(UnstakingShMonVault.NotOperator.selector);
        v.startUnstake(1);
    }
}
