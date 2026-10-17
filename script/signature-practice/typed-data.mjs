/**
 * MetaMask에 표시할 Vesting 지급 승인 데이터를 만든다.
 * 서명·토큰 승인·일정 등록은 실행하지 않는다. 마감·관리자·nonce의 현재 유효성은 체인에서 별도로 확인한다.
 * @param {string} vesting 이 승인을 사용할 Sepolia Vesting 주소.
 * @param {object} authorization 계약의 ScheduleAuthorization과 같은 여덟 필드. 정수는 정확한 십진 문자열이다.
 * @returns {object} eth_signTypedData_v4에 전달할 domain·types·message.
 */
export function buildTypedData(vesting, authorization) {
  const fields = [
    { name: 'funder', type: 'address' },
    { name: 'beneficiary', type: 'address' },
    { name: 'totalAmount', type: 'uint256' },
    { name: 'cliffDuration', type: 'uint64' },
    { name: 'duration', type: 'uint64' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
    { name: 'ownerEpoch', type: 'uint256' }
  ];
  const message = {};
  const addresses = [['vesting', vesting], ['funder', authorization?.funder], ['beneficiary', authorization?.beneficiary]];
  for (const [name, value] of addresses) {
    if (typeof value !== 'string' || !/^0x[\da-fA-F]{40}$/.test(value) || /^0x0{40}$/i.test(value)) {
      throw new Error(`${name}: 영 주소가 아닌 20바이트 주소가 필요합니다.`);
    }
  }
  for (const { name, type } of fields) {
    const value = authorization[name];
    if (type !== 'address') {
      if (typeof value !== 'string' || !/^(0|[1-9]\d*)$/.test(value)) {
        throw new Error(`${name}: 반올림되지 않은 십진 정수 문자열이 필요합니다.`);
      }
      const bits = type === 'uint64' ? 64n : 256n;
      if (BigInt(value) >= 2n ** bits) throw new Error(`${name}: ${type} 범위를 넘습니다.`);
    }
    message[name] = value;
  }
  if (BigInt(message.totalAmount) === 0n || BigInt(message.duration) === 0n) {
    throw new Error('금액과 전체 지급 기간은 0보다 커야 합니다.');
  }
  if (BigInt(message.cliffDuration) > BigInt(message.duration)) {
    throw new Error('cliff는 전체 지급 기간보다 길 수 없습니다.');
  }
  return {
    domain: { name: 'Vesting', version: '1', chainId: 11155111, verifyingContract: vesting },
    primaryType: 'ScheduleAuthorization',
    types: {
      EIP712Domain: [
        { name: 'name', type: 'string' },
        { name: 'version', type: 'string' },
        { name: 'chainId', type: 'uint256' },
        { name: 'verifyingContract', type: 'address' }
      ],
      ScheduleAuthorization: fields
    },
    message
  };
}
