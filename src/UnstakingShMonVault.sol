// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {Context} from "openzeppelin-contracts/utils/Context.sol";
import {ERC4626, ERC20, IERC20} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";

interface IShMonad {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice shMonad's own slow unstake (the same calls the vault's exit desks make): it burns the caller's shMON, so the
///         vault gives it no approval (issue 4)
interface IUnstaker {
    struct UnstakeRequest {
        uint128 amountMon;
        uint64 completionEpoch;
    }

    function requestUnstake(uint256 shares) external returns (uint64 completionEpoch);
    function completeUnstake() external;
    function getUnstakeRequests(address account) external view returns (UnstakeRequest[] memory);
    function getInternalEpoch() external view returns (uint64);
}

interface IWMON {
    function deposit() external payable;
}

/// @title UnstakingShMonVault
/// @notice EVC-compatible collateral vault for shMON that rehypothecates its shMON into the slow unstake (Root,
///         2026-11-05: "Custom vault for shMON, which does rehypothecation into slow redemption").
///         Assets are counted in shMON units: shMON held + (MON pending in the unstake + WMON held) / shMonad's rate.
///         An operator sends shMON into the unstake and completes it; the MON that comes back is held as WMON.
///         `redeemForWmon` pays a holder the WMON value of their shares, so an EVC batch can repay WMON debt with it.
///         Transfers, withdrawals and redemptions require an account status check, as Euler's ERC4626EVCCollateral does,
///         so a controller (the WMON vault) can hold and liquidate it.
///         Deployed on Monad for the shMON vaults' exit desks (2026-11-06).
///         v2 (2026-11-16, GitHub issues 1 to 3 of the 2026-11-15 audit): shares are minted only to an operator, so no
///         outsider can take matured WMON ahead of the desk; maxWithdraw / maxRedeem report what can actually leave,
///         with maxRedeemForWmon for the WMON exit; completeUnstake wraps every wei of MON the vault holds; no approval
///         to the unstaker (issue 4); startUnstake clamps to the shMON held (issue 7); completeUnstake swallows shMonad's
///         nothing-matured refusal (issue 8); redeemForWmon emits RedeemedForWmon (issue 11).
///         v3 (2026-11-17, Root: one ushMON for both desks): several operators share one vault. Each operator's unstakes
///         are kept on its own ledger, and the WMON that comes back from them is credited to that operator alone, so
///         one desk can never redeem the WMON another desk's unstake produced. MON that reaches the vault outside a
///         ledger entry (issue 3's stray MON, or WMON sent straight in) is credited to every holder pro rata.
contract UnstakingShMonVault is EVCUtil, ERC4626 {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant VIRTUAL_AMOUNT = 1e6;
    /// @dev The pro-rata pot of WMON no operator's ledger produced
    address internal constant SHARED = address(0);

    struct Pending {
        uint128 amountMon;
        uint64 completionEpoch;
    }

    IUnstaker public immutable unstaker;
    IERC20 public immutable wmon;

    /// @notice The exit desks allowed to mint shares and start unstakes; fixed at deployment
    mapping(address => bool) public isOperator;
    address[] internal _operators;
    /// @notice Each operator's unstakes still on their way, in the order they were started
    mapping(address => Pending[]) internal _ledger;
    /// @notice WMON each operator may redeem; `wmonCredit(address(0))` is the pot every holder shares pro rata
    mapping(address => uint256) public wmonCredit;
    /// @notice Every credit added up: WMON the vault holds beyond it is not yet anyone's and is credited on the next
    ///         completeUnstake
    uint256 public creditTotal;

    event UnstakeStarted(address indexed operator, uint256 shares, uint256 amountMon, uint64 completionEpoch);
    event UnstakeCompleted(uint256 mon);
    /// @notice WMON made redeemable: by the operator whose unstake produced it, or by every holder (operator 0)
    event WmonCredited(address indexed operator, uint256 wmon);
    /// @notice A redemption paid in WMON (issue 11): indexers that follow Deposit and Withdraw see these too
    event RedeemedForWmon(address indexed caller, address indexed receiver, address indexed owner, uint256 shares, uint256 wmon);

    error NotOperator();
    error NoOperators();
    error InsufficientWmon();

    constructor(address evc_, address shMon_, address unstaker_, address wmon_, address[] memory operators_)
        EVCUtil(evc_)
        ERC4626(IERC20(shMon_))
        ERC20("Unstaking shMON", "ushMON")
    {
        if (operators_.length == 0) revert NoOperators();
        unstaker = IUnstaker(unstaker_);
        wmon = IERC20(wmon_);
        for (uint256 i = 0; i < operators_.length; i++) {
            isOperator[operators_[i]] = true;
            _operators.push(operators_[i]);
        }
    }

    receive() external payable {}

    /// @notice No Permit2: depositors approve this vault directly (EulerSwap's approveVault reads this, as on EVK vaults)
    function permit2Address() external pure returns (address) {
        return address(0);
    }

    function operators() external view returns (address[] memory) {
        return _operators;
    }

    /// @notice MON per shMON from shMonad, 1e18-scaled
    function rate() public view returns (uint256) {
        return IShMonad(asset()).convertToAssets(1e18);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 monSide = pendingMon() + wmon.balanceOf(address(this));
        return IERC20(asset()).balanceOf(address(this)) + monSide.mulDiv(1e18, rate());
    }

    function _convertToShares(uint256 assets, Math.Rounding r) internal view override returns (uint256) {
        return assets.mulDiv(totalSupply() + VIRTUAL_AMOUNT, totalAssets() + VIRTUAL_AMOUNT, r);
    }

    function _convertToAssets(uint256 shares, Math.Rounding r) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets() + VIRTUAL_AMOUNT, totalSupply() + VIRTUAL_AMOUNT, r);
    }

    // ---- who may hold new shares, and what a holder can take out now

    /// @notice Shares are minted only to an operator (issue 1). A desk's EulerSwap pool deposits a seller's shMON with
    ///         the desk as receiver, and reads maxDeposit(desk) for its quote limit, so it keeps working. Shares stay
    ///         transferable, so a liquidation still seizes them.
    function maxDeposit(address receiver) public view override returns (uint256) {
        return isOperator[receiver] ? type(uint256).max : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return isOperator[receiver] ? type(uint256).max : 0;
    }

    /// @notice shMON the owner can withdraw now (issue 2): 0 while a controller may veto, else the owner's claim bounded
    ///         by the shMON the vault holds (the rest is in the unstake or already WMON), as Euler's EVK reports it
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (evc.getControllers(owner).length > 0) return 0;
        return Math.min(_convertToAssets(balanceOf(owner), Math.Rounding.Floor), IERC20(asset()).balanceOf(address(this)));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (evc.getControllers(owner).length > 0) return 0;
        return Math.min(balanceOf(owner), _convertToShares(IERC20(asset()).balanceOf(address(this)), Math.Rounding.Floor));
    }

    /// @notice WMON no operator's ledger produced: the shared pot every holder draws pro rata. It counts WMON sent
    ///         straight to the vault before any completeUnstake has credited it.
    function sharedWmon() public view returns (uint256) {
        return wmonCredit[SHARED] + (wmon.balanceOf(address(this)) - creditTotal);
    }

    /// @notice WMON the owner may redeem now: its own credit plus its pro-rata share of the shared pot
    function wmonRedeemable(address owner) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 shared = supply == 0 ? 0 : sharedWmon().mulDiv(balanceOf(owner), supply);
        return wmonCredit[owner] + shared;
    }

    /// @notice Shares the owner can redeem for WMON now: 0 while a controller may veto, else the fewer of the owner's
    ///         shares and the shares its redeemable WMON pays for at shMonad's rate
    function maxRedeemForWmon(address owner) public view returns (uint256) {
        if (evc.getControllers(owner).length > 0) return 0;
        uint256 asShmon = wmonRedeemable(owner).mulDiv(1e18, rate());
        return Math.min(balanceOf(owner), _convertToShares(asShmon, Math.Rounding.Floor));
    }

    // ---- the slow unstake

    /// @notice MON shMonad's unstake still owes this vault, matured or not
    function pendingMon() public view returns (uint256 total) {
        IUnstaker.UnstakeRequest[] memory r = unstaker.getUnstakeRequests(address(this));
        for (uint256 i = 0; i < r.length; i++) total += r[i].amountMon;
    }

    /// @notice An operator's unstakes still on their way, oldest first
    function ledgerOf(address operator) external view returns (Pending[] memory) {
        return _ledger[operator];
    }

    /// @notice Sends `shmonAmount` of the vault's shMON into the unstake, or all of it when that is less (issue 7: a wei
    ///         withdrawn ahead of an exact request must not make shMonad refuse it). Nothing to send is a no-op. The MON
    ///         shMonad now owes for it is written on the caller's ledger.
    function startUnstake(uint256 shmonAmount) external {
        address caller = _msgSender();
        if (!isOperator[caller]) revert NotOperator();
        uint256 held = IERC20(asset()).balanceOf(address(this));
        if (shmonAmount > held) shmonAmount = held;
        if (shmonAmount == 0) return;
        uint256 before = pendingMon();
        uint64 epoch = unstaker.requestUnstake(shmonAmount);
        uint256 amountMon = pendingMon() - before;
        _ledger[caller].push(Pending(uint128(amountMon), epoch));
        emit UnstakeStarted(caller, shmonAmount, amountMon, epoch);
    }

    /// @notice Completes every matured unstake (anyone may call), holds every wei of MON the vault then has as WMON, and
    ///         credits it: first to the operators whose matured ledger entries it pays, oldest first, then whatever is
    ///         left (issue 3's stray MON, WMON sent straight in) to the pot every holder shares. shMonad refuses the
    ///         call when nothing has matured; that refusal is swallowed (issue 8).
    function completeUnstake() external returns (uint256 mon) {
        try unstaker.completeUnstake() {} catch {}
        mon = address(this).balance;
        if (mon > 0) IWMON(address(wmon)).deposit{value: mon}();
        emit UnstakeCompleted(mon);
        uint256 fresh = wmon.balanceOf(address(this)) - creditTotal;
        if (fresh == 0) return mon;
        uint64 epoch = unstaker.getInternalEpoch();
        for (uint256 i = 0; i < _operators.length && fresh > 0; i++) {
            address op = _operators[i];
            Pending[] storage l = _ledger[op];
            uint256 paid;
            uint256 n;
            while (n < l.length && l[n].completionEpoch <= epoch && l[n].amountMon <= fresh - paid) {
                paid += l[n].amountMon;
                n++;
            }
            if (n == 0) continue;
            // drop the n oldest entries, keeping the order of the rest
            for (uint256 j = n; j < l.length; j++) l[j - n] = l[j];
            for (uint256 j = 0; j < n; j++) l.pop();
            _credit(op, paid);
            fresh -= paid;
        }
        if (fresh > 0) _credit(SHARED, fresh);
    }

    function _credit(address op, uint256 amount) internal {
        wmonCredit[op] += amount;
        creditTotal += amount;
        emit WmonCredited(op, amount);
    }

    // ---- WMON out, for repaying WMON debt in the same EVC batch

    /// @notice Burns `shares` of `owner` and pays their value in WMON to `receiver`, at most what `owner` may redeem
    ///         (its own credit first, then its share of the pot)
    function redeemForWmon(uint256 shares, address receiver, address owner) external returns (uint256 wmonOut) {
        address caller = _msgSender();
        if (caller != owner) _spendAllowance(owner, caller, shares);
        wmonOut = convertToAssets(shares).mulDiv(rate(), 1e18);
        if (wmonOut > wmonRedeemable(owner)) revert InsufficientWmon();
        // the owner's own credit first, then the shared pot's credited part; what is left comes from WMON not yet
        // credited, which the balance drop accounts for by itself
        uint256 own = Math.min(wmonOut, wmonCredit[owner]);
        uint256 shared = Math.min(wmonOut - own, wmonCredit[SHARED]);
        wmonCredit[owner] -= own;
        wmonCredit[SHARED] -= shared;
        creditTotal -= own + shared;
        _burn(owner, shares);
        wmon.safeTransfer(receiver, wmonOut);
        emit RedeemedForWmon(caller, receiver, owner, shares, wmonOut);
        evc.requireAccountStatusCheck(owner);
    }

    // ---- account status checks, as ERC4626EVCCollateral

    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        bool ok = super.transfer(to, amount);
        evc.requireAccountStatusCheck(_msgSender());
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        evc.requireAccountStatusCheck(from);
        return ok;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = super.withdraw(assets, receiver, owner);
        evc.requireAccountStatusCheck(owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = super.redeem(shares, receiver, owner);
        evc.requireAccountStatusCheck(owner);
    }

    function _msgSender() internal view override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }
}
