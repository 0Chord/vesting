// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    IERC20 public immutable TOKEN;
    uint256 public nextScheduleId;

    struct Schedule {
        address beneficiary;
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

    constructor(IERC20 token_, address initialOwner) Ownable(initialOwner) {
        if (address(token_) == address(0)) {
            revert InvalidToken();
        }

        TOKEN = token_;
    }

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

    function vestedAmount(uint256 scheduleId) public view returns (uint256) {
        Schedule storage schedule = _getSchedule(scheduleId);

        return _vestedAmount(schedule, block.timestamp);
    }

    function releasableAmount(uint256 scheduleId) public view returns (uint256) {
        Schedule storage schedule = _getSchedule(scheduleId);

        return _vestedAmount(schedule, block.timestamp) - schedule.claimedAmount;
    }

    function getSchedule(uint256 scheduleId) external view returns (Schedule memory) {
        return _getSchedule(scheduleId);
    }

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

        // 상태를 먼저 변경한 후 토큰 전송
        schedule.claimedAmount += amount;

        TOKEN.safeTransfer(schedule.beneficiary, amount);

        emit TokensClaimed(scheduleId, schedule.beneficiary, amount);
    }

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

        /*
         * revokedAt을 저장하면 vesting 시간이 이 시점에서 멈춘다.
         * beneficiary는 이후에도 vested - claimed 만큼 claim할 수 있다.
         */
        schedule.revoked = true;
        schedule.revokedAt = uint64(block.timestamp);

        TOKEN.safeTransfer(schedule.funder, refundAmount);

        emit ScheduleRevoked(scheduleId, vested, refundAmount);
    }

    function _vestedAmount(Schedule storage schedule, uint256 timestamp) internal view returns (uint256) {
        uint256 effectiveTime = timestamp;

        // 취소된 schedule은 취소 시점까지만 vesting된다.
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

        // totalAmount * elapsed / duration
        // 일반 곱셈 대신 mulDiv를 사용해 overflow 위험을 줄인다.
        return Math.mulDiv(schedule.totalAmount, elapsed, schedule.duration);
    }

    function _getSchedule(uint256 scheduleId) internal view returns (Schedule storage schedule) {
        if (scheduleId >= nextScheduleId) {
            revert ScheduleNotFound(scheduleId);
        }

        schedule = schedules[scheduleId];
    }
}
