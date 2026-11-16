// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IShMonadRate {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Fork-only stand-in for shMonad's slow unstake. An anvil fork cannot advance shMonad's epoch (Monad's
///         staking system contract is not on anvil: `crank` and `getEpoch` revert), so this holds the shMON and pays
///         its MON value at request time after the measured wait (19.6 h typical over 30 days, unstake-timing-30d.md).
///         It is pre-funded with native MON. Never deployed outside a fork.
contract UnstakeStandIn {
    IERC20 public immutable shMon;
    uint256 public immutable waitSeconds;

    struct UnstakeRequest {
        uint128 amountMon;
        uint64 completionEpoch; // the stand-in has no epochs; this holds the ready time in seconds
    }

    mapping(address => UnstakeRequest[]) internal requests;

    constructor(address shMon_, uint256 waitSeconds_) {
        shMon = IERC20(shMon_);
        waitSeconds = waitSeconds_;
    }

    receive() external payable {}

    /// @notice Takes `shares` of shMON and promises their MON value now, payable after the wait (shMonad's calls)
    function requestUnstake(uint256 shares) external returns (uint64 completionEpoch) {
        shMon.transferFrom(msg.sender, address(this), shares);
        completionEpoch = uint64(block.timestamp + waitSeconds);
        requests[msg.sender].push(UnstakeRequest(uint128(IShMonadRate(address(shMon)).convertToAssets(shares)), completionEpoch));
    }

    function getUnstakeRequests(address account) external view returns (UnstakeRequest[] memory) {
        return requests[account];
    }

    /// @notice MON still owed to `account`, matured or not
    function pendingMon(address account) public view returns (uint256 total) {
        UnstakeRequest[] storage r = requests[account];
        for (uint256 i = 0; i < r.length; i++) total += r[i].amountMon;
    }

    /// @notice Pays every matured request in native MON
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
        if (paid > 0) {
            (bool ok,) = msg.sender.call{value: paid}("");
            require(ok, "pay failed");
        }
    }
}
