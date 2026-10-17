// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title ERC20 Token Vesting
/// @notice Releases a single ERC20 token through owner-managed linear vesting schedules.
/// @dev The cliff delays claims, but vesting is calculated from the schedule's start time.
contract Vesting is Ownable, ReentrancyGuard, EIP712 {
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
    /// @notice 등록 마감 시각이 지났다. 이미 생성된 일정의 청구 기한을 뜻하지 않는다.
    error AuthorizationExpired(uint256 deadline);
    /// @notice 서명에 적힌 제공자가 현재 관리자가 아니거나 영 주소다.
    error InvalidAuthorizationFunder(address funder);
    /// @notice 관리자 변경으로 해당 재임 때의 미등록 승인이 무효화됐다.
    error InvalidAuthorizationEpoch(uint256 expected, uint256 supplied);
    /// @notice 같은 재임 번호에서 이미 등록에 사용한 승인 번호다.
    error AuthorizationAlreadyUsed(uint256 ownerEpoch, uint256 nonce);
    /// @notice 이 계약·체인·승인 내용에 대한 제공자의 유효한 서명이 아니다.
    error InvalidAuthorizationSignature();

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

    /// @notice 사용한 승인 번호와 생성된 일정 ID를 연결한다.
    event ScheduleAuthorizationUsed(uint256 indexed ownerEpoch, uint256 indexed nonce, uint256 indexed scheduleId);

    /// @notice 등록 시 시작하는 지급 승인 메시지의 EIP-712 타입 해시다.
    bytes32 public constant SCHEDULE_AUTHORIZATION_TYPEHASH = keccak256(
        "ScheduleAuthorization(address funder,address beneficiary,uint256 totalAmount,uint64 cliffDuration,uint64 duration,uint256 nonce,uint256 deadline,uint256 ownerEpoch)"
    );

    /// @notice 관리자 주소가 바뀔 때 증가하여 이전 재임 때의 미사용 승인을 무효화한다.
    /// @dev 최초 관리자 설정은 1이다. 같은 주소로 이전하는 호출은 증가시키지 않는다.
    uint256 public ownerEpoch;

    /// @notice 관리자 변경 번호별로 성공한 등록에 사용한 승인 번호를 기록한다.
    mapping(uint256 epoch => mapping(uint256 nonce => bool used)) public usedAuthorizations;

    /// @notice 관리자가 서명할 지급 조건이다. 시작 시각은 등록 성공 블록에서 결정한다.
    /// @dev deadline은 등록 마감이며 duration이나 생성된 일정의 청구 기한과 다르다.
    struct ScheduleAuthorization {
        address funder;
        address beneficiary;
        uint256 totalAmount;
        uint64 cliffDuration;
        uint64 duration;
        uint256 nonce;
        uint256 deadline;
        uint256 ownerEpoch;
    }

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
    constructor(IERC20 token_, address initialOwner) Ownable(initialOwner) EIP712("Vesting", "1") {
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
        uint64 actualStartTime = startTime == 0 ? uint64(block.timestamp) : startTime;
        return _createSchedule(msg.sender, beneficiary, totalAmount, actualStartTime, cliffDuration, duration);
    }

    /// @notice 지정 수령자가 관리자 서명을 제출하고 관리자 자금을 예치하여 일정을 만든다.
    /// @dev 성공한 거래의 블록 시각부터 시작한다. 어느 단계든 실패하면 승인 사용 기록도 되돌아간다.
    /// @param authorization 제공자·수령자·지급량·기간·승인 번호·등록 마감·관리자 변경 번호.
    /// @param signature 제공자의 EIP-712 서명. 계약 계정은 ERC-1271로 검증한다.
    /// @return scheduleId 새 일정의 ID. 승인 번호인 nonce와는 별개다.
    function createScheduleWithSignature(ScheduleAuthorization calldata authorization, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 scheduleId)
    {
        if (msg.sender != authorization.beneficiary) revert NotBeneficiary();
        // 등록 마감은 합의한 블록 시각 기준이며, 벽시계의 정확한 송신 시각을 보장하지 않는다.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > authorization.deadline) revert AuthorizationExpired(authorization.deadline);
        _checkAuthorizationAuthority(authorization);
        if (usedAuthorizations[authorization.ownerEpoch][authorization.nonce]) {
            revert AuthorizationAlreadyUsed(authorization.ownerEpoch, authorization.nonce);
        }
        if (!SignatureChecker.isValidSignatureNow(
                authorization.funder, hashScheduleAuthorization(authorization), signature
            )) {
            revert InvalidAuthorizationSignature();
        }

        usedAuthorizations[authorization.ownerEpoch][authorization.nonce] = true;
        scheduleId = _createSchedule(
            authorization.funder,
            authorization.beneficiary,
            authorization.totalAmount,
            SafeCast.toUint64(block.timestamp),
            authorization.cliffDuration,
            authorization.duration
        );
        // 토큰을 외부 호출하는 도중 관리자가 바뀌면 등록 전체를 되돌린다.
        _checkAuthorizationAuthority(authorization);
        emit ScheduleAuthorizationUsed(authorization.ownerEpoch, authorization.nonce, scheduleId);
    }

    /// @notice 이 계약과 체인에 연결된 지급 승인 서명용 해시를 반환한다.
    /// @dev 미사용 여부나 마감은 보장하지 않으며 등록할 때 별도로 검사한다.
    /// @param authorization 해시를 계산할 지급 승인 조건.
    /// @return digest EIP-712 도메인과 전체 승인 내용을 결합한 해시.
    function hashScheduleAuthorization(ScheduleAuthorization calldata authorization)
        public
        view
        returns (bytes32 digest)
    {
        bytes32 body = keccak256(
            abi.encode(
                SCHEDULE_AUTHORIZATION_TYPEHASH,
                authorization.funder,
                authorization.beneficiary,
                authorization.totalAmount,
                authorization.cliffDuration,
                authorization.duration,
                authorization.nonce,
                authorization.deadline,
                authorization.ownerEpoch
            )
        );
        return _hashTypedDataV4(body);
    }

    /// @dev 직접 생성과 서명 등록에 같은 입력 검증·전액 예치·일정 저장 규칙을 적용한다.
    /// @param funder 토큰을 예치하고 취소 시 미확정 몫을 돌려받을 최초 제공자.
    /// @param beneficiary 해당 일정의 지급액을 청구할 수령자.
    /// @param totalAmount 전액 예치해야 할 토큰 최소 단위 총량.
    /// @param startTime 호출 경로에서 확정한 지급 시작 시각.
    /// @param cliffDuration 시작 시각부터 청구가 잠기는 기간.
    /// @param duration cliff를 포함한 전체 지급 기간.
    /// @return scheduleId 저장한 새 일정의 ID.
    function _createSchedule(
        address funder,
        address beneficiary,
        uint256 totalAmount,
        uint64 startTime,
        uint64 cliffDuration,
        uint64 duration
    ) internal returns (uint256 scheduleId) {
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

        uint256 balanceBefore = TOKEN.balanceOf(address(this));

        TOKEN.safeTransferFrom(funder, address(this), totalAmount);

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
            funder: funder,
            totalAmount: totalAmount,
            claimedAmount: 0,
            startTime: startTime,
            cliffDuration: cliffDuration,
            duration: duration,
            revokedAt: 0,
            revoked: false
        });

        emit ScheduleCreated(scheduleId, beneficiary, funder, totalAmount, startTime, cliffDuration, duration);
    }

    /// @dev 현 관리자와 재임 번호를 확인하며 소유권 포기 후의 영 주소도 거절한다.
    /// @param authorization 서명한 제공자와 관리자 변경 번호를 담은 승인.
    function _checkAuthorizationAuthority(ScheduleAuthorization calldata authorization) internal view {
        if (authorization.funder == address(0) || authorization.funder != owner()) {
            revert InvalidAuthorizationFunder(authorization.funder);
        }
        if (authorization.ownerEpoch != ownerEpoch) {
            revert InvalidAuthorizationEpoch(ownerEpoch, authorization.ownerEpoch);
        }
    }

    /// @dev 주소가 실제로 바뀔 때만 새 재임 번호를 발급한다. 소유권 포기에도 적용된다.
    /// @param newOwner 새 관리자. 소유권 포기 시에는 영 주소다.
    function _transferOwnership(address newOwner) internal override {
        if (owner() != newOwner) ownerEpoch++;
        super._transferOwnership(newOwner);
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
