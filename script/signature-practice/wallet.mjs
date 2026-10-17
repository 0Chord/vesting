import { buildTypedData } from './typed-data.mjs';

// 이번 Sepolia 배포의 공개 주소다. 다른 배포에서 실습하려면 이 주소들도 함께 바꾼다.
export const DEPLOYMENT = Object.freeze({
  vesting: '0x2ce49c26cde36e861922e313dbae004583e628be',
  token: '0x7e61a37fce010ad620b052273d23efe5dc94bba8',
  funder: '0x2e8b51228117b9f2916ad9dc254522f8786a4c2e',
  beneficiary: '0x4ee3e1bf5e788c0f844fa9e5a8fbda16ad421d69'
});
const word = value => BigInt(value).toString(16).padStart(64, '0');
const addressWord = value => value.slice(2).toLowerCase().padStart(64, '0');

/**
 * 지갑 한 개의 실습 상태를 관리한다. 읽기 RPC와 메시지 서명만 요청한다.
 * @param {object} provider 사용자가 고른 EIP-1193 지갑 provider.
 * @returns {object} 연결·조건 준비·서명·이전 결과 무효화 함수.
 */
export function createPractice(provider) {
  let revision = 0;
  let prepared;
  const request = (method, params = []) => provider.request({ method, params });
  const invalidate = () => { revision++; prepared = undefined; };
  const unchanged = ticket => {
    if (ticket !== revision) throw new Error('계정·체인·입력이 바뀌었습니다. 조건을 다시 확인하세요.');
  };

  /** 연결된 첫 계정이 P이고 체인이 Sepolia인지 확인한다. 자동 전환하지 않는다. */
  async function checkWallet() {
    const chain = await request('eth_chainId');
    const accounts = await request('eth_accounts');
    if (BigInt(chain) !== 11155111n) throw new Error('MetaMask에서 Sepolia를 선택하세요.');
    if (accounts[0]?.toLowerCase() !== DEPLOYMENT.funder) throw new Error('MetaMask에서 제공자 P 계정을 선택하세요.');
  }

  /** 한 블록을 기준으로 관리자·재임 번호·nonce·토큰을 읽는다. */
  async function readState(nonce) {
    await checkWallet();
    const block = await request('eth_getBlockByNumber', ['latest', false]);
    if (!block?.number || !block.timestamp) throw new Error('최신 블록을 읽지 못했습니다.');
    const call = async (to, data) => {
      const result = await request('eth_call', [{ to, data }, block.number]);
      if (!/^0x[\da-f]{64}$/i.test(result)) throw new Error('계약 조회 응답이 올바르지 않습니다.');
      return result;
    };
    const [owner, token, epoch] = await Promise.all([
      call(DEPLOYMENT.vesting, '0x8da5cb5b'), // owner()
      call(DEPLOYMENT.vesting, '0x82bfefc8'), // TOKEN()
      call(DEPLOYMENT.vesting, '0xd6dfcf6c')  // ownerEpoch()
    ]);
    if (owner.slice(-40).toLowerCase() !== DEPLOYMENT.funder.slice(2)) throw new Error('현재 관리자가 P가 아닙니다.');
    if (token.slice(-40).toLowerCase() !== DEPLOYMENT.token.slice(2)) throw new Error('배포의 TOKEN이 지정 MTK와 다릅니다.');
    const [used, decimals] = await Promise.all([
      call(DEPLOYMENT.vesting, '0x0165897f' + word(epoch) + word(nonce)),
      call(DEPLOYMENT.token, '0x313ce567') // decimals()
    ]);
    if (BigInt(used) !== 0n) throw new Error('이미 사용한 nonce입니다. 다른 번호로 다시 확인하세요.');
    if (BigInt(decimals) !== 18n) throw new Error('이번 예제는 소수점 18자리 MTK용입니다.');
    await checkWallet();
    return { epoch: BigInt(epoch).toString(), timestamp: BigInt(block.timestamp) };
  }

  return {
    invalidate,
    /** 사용자가 연결 버튼을 눌렀을 때만 계정 접근을 요청한다. */
    async connect() {
      invalidate();
      await request('eth_requestAccounts');
      await checkWallet();
    },
    /** 현재 블록부터 한 시간 뒤를 마감으로 정하고, 화면에 보여줄 승인 사본을 돌려준다. */
    async prepare(nonce) {
      invalidate();
      const ticket = revision;
      if (typeof nonce !== 'string' || !/^(0|[1-9]\d*)$/.test(nonce) || BigInt(nonce) >= 2n ** 256n) {
        throw new Error('nonce는 uint256 범위의 십진 정수로 입력하세요.');
      }
      const state = await readState(nonce);
      const typedData = buildTypedData(DEPLOYMENT.vesting, {
        funder: DEPLOYMENT.funder, beneficiary: DEPLOYMENT.beneficiary,
        totalAmount: '100000000000000000000', cliffDuration: '120', duration: '600',
        nonce, deadline: (state.timestamp + 3600n).toString(), ownerEpoch: state.epoch
      });
      unchanged(ticket);
      // 호출자가 화면용 사본을 수정해도, 실제 서명할 내용은 바뀌지 않는다.
      prepared = JSON.stringify(typedData);
      return typedData;
    },
    /**
     * 미리 본 조건 그대로 서명을 요청한다. 전후 상태가 달라지면 결과를 버린다.
     * @returns {object} B에게 전달할 typedData와 P의 서명. 토큰 전송이나 등록 영수증은 아니다.
     */
    async sign() {
      if (!prepared) throw new Error('먼저 조건을 확인하세요.');
      const ticket = revision;
      const typedData = JSON.parse(prepared);
      const { message } = typedData;
      const checkCurrent = async () => {
        const state = await readState(message.nonce);
        if (state.epoch !== message.ownerEpoch) throw new Error('관리자 재임 번호가 바뀌었습니다. 조건을 다시 확인하세요.');
        if (state.timestamp > BigInt(message.deadline)) throw new Error('등록 마감이 지났습니다. 조건을 다시 확인하세요.');
        unchanged(ticket);
      };
      // 성공·거절·실패 모두 다시 확인한 뒤에만 다음 서명을 요청할 수 있다.
      prepared = undefined;
      await checkCurrent();
      const signature = await request('eth_signTypedData_v4', [DEPLOYMENT.funder, JSON.stringify(typedData)]);
      await checkCurrent();
      if (!/^0x[\da-f]{130}$/i.test(signature)) throw new Error('65바이트 서명 응답이 아닙니다.');
      const r = signature.slice(2, 66), s = signature.slice(66, 130), v = BigInt('0x' + signature.slice(130));
      if (![27n, 28n].includes(v) || BigInt('0x' + s) > BigInt('0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0')) {
        throw new Error('계약에서 받는 ECDSA 서명 형식이 아닙니다.');
      }
      // 계약이 계산한 digest와 EVM의 ecrecover(주소 1)로 실제 서명자를 확인한다.
      const body = addressWord(message.funder) + addressWord(message.beneficiary)
        + ['totalAmount', 'cliffDuration', 'duration', 'nonce', 'deadline', 'ownerEpoch'].map(key => word(message[key])).join('');
      const digest = await request('eth_call', [{ to: DEPLOYMENT.vesting, data: '0xa2e0cbe7' + body }, 'latest']);
      if (!/^0x[\da-f]{64}$/i.test(digest)) throw new Error('계약의 승인 해시를 읽지 못했습니다.');
      const recovered = await request('eth_call', [{ to: '0x0000000000000000000000000000000000000001', data: digest + word(v) + r + s }, 'latest']);
      if (recovered.toLowerCase() !== '0x' + addressWord(DEPLOYMENT.funder)) throw new Error('이 조건에 서명한 주소가 P와 다릅니다.');
      await checkCurrent();
      return { typedData, signature };
    }
  };
}
