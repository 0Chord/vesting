// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ERC20 Token Vesting
/// @notice Releases a single ERC20 token through owner-managed linear vesting schedules.
/// @dev The cliff delays claims, but vesting is calculated from the schedule's start time.
contract Vesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidToken();
    error InvalidBeneficiary();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidCliff();
    error ScheduleNotFound(uint256 scheduleId);
    error NotBeneficiary();
    error NothingToClaim();
    error AlreadyRevoked();
    error NothingToRevoke();
    error UnsupportedToken(uint256 expected, uint256 received);

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed funder,
        uint256 totalAmount,
        uint64 startTime,
        uint64 cliffDuration,
        uint64 duration
    );

    event TokensClaimed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);

    event ScheduleRevoked(uint256 indexed scheduleId, uint256 vestedAmount, uint256 refundedAmount);

    /// @notice Token distributed by every schedule in this contract.
    IERC20 public immutable TOKEN;

    /// @notice ID that will be assigned to the next schedule.
    uint256 public nextScheduleId;

    /// @dev Times are stored as Unix timestamps or durations in seconds.
    struct Schedule {
        address beneficiary;
        /// @dev Receives the unvested balance if the schedule is revoked.
        address funder;
        uint256 totalAmount;
        uint256 claimedAmount;
        uint64 startTime;
        uint64 cliffDuration;
        uint64 duration;
        uint64 revokedAt;
        bool revoked;
    }

    mapping(uint256 => Schedule) private schedules;

    /// @param token_ ERC20 token distributed by this contract.
    /// @param initialOwner Address allowed to create and revoke schedules.
    constructor(IERC20 token_, address initialOwner) Ownable(initialOwner) {
        if (address(token_) == address(0)) {
            revert InvalidToken();
        }

        TOKEN = token_;
    }

    /// @notice Creates a schedule and deposits its full token allocation.
    /// @dev The owner must approve `totalAmount` first. Passing zero for `startTime` uses the current block time.
    /// @param beneficiary Address that can claim vested tokens.
    /// @param totalAmount Total number of tokens allocated to the schedule.
    /// @param startTime Unix timestamp when vesting starts, or zero to start immediately.
    /// @param cliffDuration Time from the start until the first claim can be made.
    /// @param duration Total vesting duration measured from the start.
    /// @return scheduleId ID assigned to the new schedule.
    function createSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint64 startTime,
        uint64 cliffDuration,
        uint64 duration
    ) external onlyOwner nonReentrant returns (uint256 scheduleId) {
        if (beneficiary == address(0)) {
            revert InvalidBeneficiary();
        }

        if (totalAmount == 0) {
            revert InvalidAmount();
        }

        if (duration == 0) {
            revert InvalidDuration();
        }

        if (cliffDuration > duration) {
            revert InvalidCliff();
        }

        uint64 actualStartTime = startTime == 0 ? uint64(block.timestamp) : startTime;

        uint256 balanceBefore = TOKEN.balanceOf(address(this));

        TOKEN.safeTransferFrom(msg.sender, address(this), totalAmount);

        uint256 balanceAfter = TOKEN.balanceOf(address(this));

        if (balanceAfter < balanceBefore) {
            revert UnsupportedToken(totalAmount, 0);
        }

        uint256 receivedAmount = balanceAfter - balanceBefore;

        if (receivedAmount != totalAmount) {
            revert UnsupportedToken(totalAmount, receivedAmount);
        }

        scheduleId = nextScheduleId++;

        schedules[scheduleId] = Schedule({
            beneficiary: beneficiary,
            funder: msg.sender,
            totalAmount: totalAmount,
            claimedAmount: 0,
            startTime: actualStartTime,
            cliffDuration: cliffDuration,
            duration: duration,
            revokedAt: 0,
            revoked: false
        });

        emit ScheduleCreated(scheduleId, beneficiary, msg.sender, totalAmount, actualStartTime, cliffDuration, duration);
    }

    /// @notice Returns the total amount vested so far, including tokens already claimed.
    /// @param scheduleId ID of the schedule to inspect.
    /// @return Total vested amount at the current block time.
    function vestedAmount(uint256 scheduleId) public view returns (uint256) {
        Schedule storage schedule = _getSchedule(scheduleId);

        return _vestedAmount(schedule, block.timestamp);
    }

    /// @notice Returns the amount currently available to claim.
    /// @param scheduleId ID of the schedule to inspect.
    /// @return Vested amount that has not been claimed yet.
    function releasableAmount(uint256 scheduleId) public view returns (uint256) {
        Schedule storage schedule = _getSchedule(scheduleId);

        return _vestedAmount(schedule, block.timestamp) - schedule.claimedAmount;
    }

    /// @notice Returns the stored data for a schedule.
    /// @param scheduleId ID of the schedule to inspect.
    /// @return Schedule data stored for the given ID.
    function getSchedule(uint256 scheduleId) external view returns (Schedule memory) {
        return _getSchedule(scheduleId);
    }

    /// @notice Claims every token currently available to the beneficiary.
    /// @param scheduleId ID of the schedule to claim from.
    /// @return amount Number of tokens transferred to the beneficiary.
    function claim(uint256 scheduleId) external nonReentrant returns (uint256 amount) {
        Schedule storage schedule = _getSchedule(scheduleId);

        if (msg.sender != schedule.beneficiary) {
            revert NotBeneficiary();
        }

        uint256 vested = _vestedAmount(schedule, block.timestamp);

        amount = vested - schedule.claimedAmount;

        if (amount == 0) {
            revert NothingToClaim();
        }

        // Update state before calling the token contract.
        schedule.claimedAmount += amount;

        TOKEN.safeTransfer(schedule.beneficiary, amount);

        emit TokensClaimed(scheduleId, schedule.beneficiary, amount);
    }

    /// @notice Stops a schedule and returns its unvested tokens to the original funder.
    /// @dev Vested but unclaimed tokens remain available to the beneficiary.
    /// @param scheduleId ID of the schedule to revoke.
    function revoke(uint256 scheduleId) external onlyOwner nonReentrant {
        Schedule storage schedule = _getSchedule(scheduleId);

        if (schedule.revoked) {
            revert AlreadyRevoked();
        }

        uint256 vested = _vestedAmount(schedule, block.timestamp);

        uint256 refundAmount = schedule.totalAmount - vested;

        if (refundAmount == 0) {
            revert NothingToRevoke();
        }

        // Freeze accrual at the revocation timestamp.
        schedule.revoked = true;
        schedule.revokedAt = uint64(block.timestamp);

        TOKEN.safeTransfer(schedule.funder, refundAmount);

        emit ScheduleRevoked(scheduleId, vested, refundAmount);
    }

    /// @dev Calculates total vested tokens at `timestamp` and freezes time at revocation.
    function _vestedAmount(Schedule storage schedule, uint256 timestamp) internal view returns (uint256) {
        uint256 effectiveTime = timestamp;

        if (schedule.revoked && effectiveTime > schedule.revokedAt) {
            effectiveTime = schedule.revokedAt;
        }

        uint256 start = schedule.startTime;
        uint256 cliffTime = start + schedule.cliffDuration;
        uint256 endTime = start + schedule.duration;

        if (effectiveTime < cliffTime) {
            return 0;
        }

        if (effectiveTime >= endTime) {
            return schedule.totalAmount;
        }

        uint256 elapsed = effectiveTime - start;

        // Avoid overflow in totalAmount * elapsed.
        return Math.mulDiv(schedule.totalAmount, elapsed, schedule.duration);
    }

    /// @dev Returns the storage reference for an existing schedule.
    function _getSchedule(uint256 scheduleId) internal view returns (Schedule storage schedule) {
        if (scheduleId >= nextScheduleId) {
            revert ScheduleNotFound(scheduleId);
        }

        schedule = schedules[scheduleId];
    }
}
