import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildTypedData } from '../../script/signature-practice/typed-data.mjs';

const vesting = '0x2ce49c26cde36e861922e313dbae004583e628be';
const funder = '0x2E8B51228117B9f2916ad9dC254522F8786A4C2E';
const beneficiary = '0x4ee3E1BF5E788C0F844fA9e5A8FbDA16AD421d69';
const authorization = () => ({
  funder, beneficiary, totalAmount: '100000000000000000000',
  cliffDuration: '120', duration: '600', nonce: '7', deadline: '1800003600', ownerEpoch: '1'
});

test('100 MTK의 최소 단위와 모든 승인 조건을 새 Sepolia 계약의 domain에 연결한다', () => {
  const result = buildTypedData(vesting, authorization());
  assert.deepEqual(result.domain, { name: 'Vesting', version: '1', chainId: 11155111, verifyingContract: vesting });
  assert.equal(result.primaryType, 'ScheduleAuthorization');
  assert.deepEqual(result.message, {
    funder, beneficiary, totalAmount: '100000000000000000000',
    cliffDuration: '120', duration: '600', nonce: '7', deadline: '1800003600', ownerEpoch: '1'
  });
  assert.equal(result.types.ScheduleAuthorization.map(field => `${field.type} ${field.name}`).join(','),
    'address funder,address beneficiary,uint256 totalAmount,uint64 cliffDuration,uint64 duration,uint256 nonce,uint256 deadline,uint256 ownerEpoch');
  assert.equal(Object.hasOwn(result.message, 'startTime'), false);
});

test('서명 수량이 반올림되는 JavaScript Number와 Solidity 정수 범위 초과를 거절한다', () => {
  for (const patch of [
    { totalAmount: 100_000_000_000_000_000_000 },
    { nonce: '9007199254740992.5' },
    { duration: (2n ** 64n).toString() },
    { nonce: (2n ** 256n).toString() }
  ]) assert.throws(() => buildTypedData(vesting, { ...authorization(), ...patch }));
  const large = (2n ** 256n - 1n).toString();
  assert.equal(buildTypedData(vesting, { ...authorization(), nonce: large }).message.nonce, large);
});

test('영 주소·0 금액·잘못된 기간을 거절하고 수정한 입력으로 새 데이터를 만들 수 있다', () => {
  const zero = '0x' + '0'.repeat(40);
  assert.throws(() => buildTypedData(zero, authorization()));
  for (const patch of [
    { funder: zero }, { beneficiary: 'not-an-address' }, { totalAmount: '0' },
    { duration: '0' }, { cliffDuration: '601' }
  ]) assert.throws(() => buildTypedData(vesting, { ...authorization(), ...patch }));
  assert.equal(buildTypedData(vesting, authorization()).message.totalAmount, '100000000000000000000');
});

test('다른 승인을 준비해도 이전 메시지와 입력의 nonce가 바뀌지 않는다', () => {
  const input = authorization();
  const first = buildTypedData(vesting, input);
  input.nonce = '8';
  const second = buildTypedData(vesting, input);
  assert.equal(first.message.nonce, '7');
  assert.equal(second.message.nonce, '8');
  second.types.ScheduleAuthorization[0].name = 'changed';
  assert.equal(first.types.ScheduleAuthorization[0].name, 'funder');
});
