import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPractice, DEPLOYMENT } from '../../script/signature-practice/wallet.mjs';

const word = value => BigInt(value).toString(16).padStart(64, '0');
const address = value => '0x' + value.slice(2).padStart(64, '0');
const signature = '0x' + '11'.repeat(32) + '22'.repeat(32) + '1b';

/** 지갑 응답을 바꾸며 서명 요청 전후의 거절 조건을 검증한다. 실제 암호 검증은 별도 실행한다. */
function wallet() {
  const state = { chain: '0xaa36a7', account: DEPLOYMENT.funder, owner: DEPLOYMENT.funder,
    epoch: 1n, timestamp: 1800000000n, used: false, recovered: DEPLOYMENT.funder, signature };
  const calls = [];
  return { state, calls, async request({ method, params }) {
    calls.push({ method, params });
    if (method === 'eth_chainId') return state.chain;
    if (method === 'eth_accounts' || method === 'eth_requestAccounts') return [state.account];
    if (method === 'eth_getBlockByNumber') return { number: '0xb', timestamp: '0x' + state.timestamp.toString(16) };
    if (method === 'eth_signTypedData_v4') {
      if (state.error) throw state.error;
      await state.onSign?.();
      return state.signature;
    }
    assert.equal(method, 'eth_call');
    const { to, data } = params[0];
    if (to.endsWith('0001')) {
      assert.equal(data.length, 258); // digest·v·r·s는 각각 32바이트다.
      assert.equal(data.slice(0, 66), '0x' + 'ab'.repeat(32));
      assert.equal(data.slice(66, 130), word(27));
      return address(state.recovered);
    }
    switch (data.slice(0, 10)) {
      case '0x8da5cb5b': return address(state.owner);
      case '0x82bfefc8': return address(DEPLOYMENT.token);
      case '0xd6dfcf6c': return '0x' + word(state.epoch);
      case '0x0165897f':
        assert.equal(data, '0x0165897f' + word(state.epoch) + word(7));
        return '0x' + word(state.used ? 1 : 0);
      case '0x313ce567': return '0x' + word(18);
      case '0xa2e0cbe7': {
        const message = JSON.parse(calls.find(call => call.method === 'eth_signTypedData_v4').params[1]).message;
        const words = [address(message.funder).slice(2), address(message.beneficiary).slice(2),
          ...['totalAmount', 'cliffDuration', 'duration', 'nonce', 'deadline', 'ownerEpoch'].map(key => word(message[key]))];
        assert.equal(data, '0xa2e0cbe7' + words.join(''));
        return '0x' + 'ab'.repeat(32);
      }
      default: assert.fail(`예상하지 않은 RPC: ${data}`);
    }
  } };
}

test('조건 미리보기와 동일한 데이터만 P에게 서명 요청하고 거래를 보내지 않는다', async () => {
  const provider = wallet(), practice = createPractice(provider);
  await practice.connect();
  const preview = await practice.prepare('7');
  assert.equal(preview.message.deadline, '1800003600');
  assert.equal(preview.message.ownerEpoch, '1');
  const original = structuredClone(preview);
  preview.message.totalAmount = '1'; // 화면용 사본 변경은 승인 내용을 바꾸지 않는다.
  const result = await practice.sign();
  const signed = provider.calls.find(call => call.method === 'eth_signTypedData_v4');
  assert.deepEqual(signed.params, [DEPLOYMENT.funder, JSON.stringify(original)]);
  assert.deepEqual(result, { typedData: original, signature });
  assert.equal(provider.calls.some(call => call.method.includes('sendTransaction')), false);
  await assert.rejects(practice.sign(), /먼저 조건/);
});

test('체인·계정·관리자·epoch·사용 nonce·만료가 달라지면 서명 창을 열지 않는다', async () => {
  for (const [key, value, error] of [
    ['chain', '0x1', /Sepolia/], ['account', DEPLOYMENT.beneficiary, /제공자/],
    ['owner', DEPLOYMENT.beneficiary, /관리자/], ['epoch', 2n, /재임/],
    ['used', true, /이미 사용/], ['timestamp', 1800003601n, /마감/]
  ]) {
    const provider = wallet(), practice = createPractice(provider);
    await practice.prepare('7');
    provider.state[key] = value;
    await assert.rejects(practice.sign(), error);
    assert.equal(provider.calls.some(call => call.method === 'eth_signTypedData_v4'), false);
  }
});

test('등록 마감과 같은 블록 시각까지는 서명 확인을 허용한다', async () => {
  const provider = wallet(), practice = createPractice(provider);
  await practice.prepare('7');
  provider.state.timestamp = 1800003600n;
  assert.equal((await practice.sign()).signature, signature);
});

test('서명 도중 입력 무효화·계정 변경·epoch 변경·nonce 사용이 생기면 결과를 반환하지 않는다', async () => {
  for (const change of [
    (provider, practice) => practice.invalidate(),
    provider => { provider.state.account = DEPLOYMENT.beneficiary; },
    provider => { provider.state.epoch = 2n; },
    provider => { provider.state.used = true; }
  ]) {
    const provider = wallet(), practice = createPractice(provider);
    await practice.prepare('7');
    provider.state.onSign = () => change(provider, practice);
    await assert.rejects(practice.sign());
    await assert.rejects(practice.sign(), /먼저 조건/);
  }
});

test('지갑 거절·다른 서명자·잘못된 서명 형식 후에는 조건부터 다시 확인한다', async () => {
  for (const patch of [
    { error: Object.assign(new Error('거절'), { code: 4001 }) },
    { recovered: DEPLOYMENT.beneficiary }, { signature: '0x1234' },
    { signature: '0x' + '11'.repeat(32) + 'ff'.repeat(32) + '1b' }
  ]) {
    const provider = wallet(), practice = createPractice(provider);
    await practice.prepare('7');
    Object.assign(provider.state, patch);
    await assert.rejects(practice.sign());
    await assert.rejects(practice.sign(), /먼저 조건/);
  }
});

test('잘못된 nonce는 RPC 전에 거절하고 계정 접근은 연결 버튼에서만 요청한다', async () => {
  for (const nonce of ['-1', '1.5', '01', (2n ** 256n).toString()]) {
    const provider = wallet();
    await assert.rejects(createPractice(provider).prepare(nonce), /nonce/);
    assert.equal(provider.calls.length, 0);
  }
  const provider = wallet();
  await createPractice(provider).prepare('7');
  assert.equal(provider.calls.some(call => call.method === 'eth_requestAccounts'), false);
});
