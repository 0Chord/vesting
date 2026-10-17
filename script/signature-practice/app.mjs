import { createPractice, DEPLOYMENT } from './wallet.mjs';

const element = id => document.getElementById(id);
const wallets = [];
let practice, activeProvider, result, busy = false;
element('addresses').textContent = `P: ${DEPLOYMENT.funder} / B: ${DEPLOYMENT.beneficiary} / Vesting: ${DEPLOYMENT.vesting}`;

/** 계정·체인·입력이 바뀌면 미리 본 조건과 서명 파일을 화면에서도 폐기한다. */
function reset(message = '조건을 다시 확인하세요.') {
  practice?.invalidate();
  result = undefined;
  element('preview').hidden = true;
  element('typed-data').textContent = '';
  element('download').hidden = true;
  element('sign').disabled = true;
  element('status').textContent = message;
}

/** 같은 화면에서 요청이 겹치지 않게 하고, 지갑 거절·RPC 오류를 표시한다. */
async function run(action) {
  if (busy) return;
  busy = true;
  for (const id of ['connect', 'prepare', 'sign', 'nonce', 'wallet']) element(id).disabled = true;
  try { await action(); }
  catch (error) { reset(error.code === 4001 ? '지갑 요청을 취소했습니다. 조건을 다시 확인하세요.' : error.message); }
  finally {
    busy = false;
    element('wallet').disabled = false;
    element('nonce').disabled = false;
    element('connect').disabled = wallets.length === 0;
    element('prepare').disabled = !practice;
    element('sign').disabled = element('preview').hidden || Boolean(result);
  }
}

// EIP-6963으로 발견한 지갑을 사용자에게 보여주고, 선택한 provider만 사용한다.
window.addEventListener('eip6963:announceProvider', ({ detail }) => {
  if (detail.info.rdns !== 'io.metamask' || wallets.some(wallet => wallet.provider === detail.provider)) return;
  wallets.push(detail);
  const option = document.createElement('option');
  option.value = String(wallets.length - 1);
  option.textContent = detail.info.name;
  if (wallets.length === 1) element('wallet').replaceChildren();
  element('wallet').append(option);
  if (!busy) element('connect').disabled = false;
});
window.dispatchEvent(new Event('eip6963:requestProvider'));
element('status').textContent = '지갑을 고른 뒤 연결하세요. 목록이 비어 있으면 Chrome의 MetaMask 확장 기능을 켜고 새로고침하세요.';

element('wallet').addEventListener('change', () => {
  reset('선택한 지갑을 다시 연결하세요.');
  practice = undefined;
  element('prepare').disabled = true;
});
element('nonce').addEventListener('input', () => reset());
element('connect').addEventListener('click', () => run(async () => {
  reset();
  if (activeProvider) {
    activeProvider.removeListener('accountsChanged', changed);
    activeProvider.removeListener('chainChanged', changed);
    activeProvider.removeListener('disconnect', changed);
  }
  activeProvider = wallets[Number(element('wallet').value)].provider;
  practice = createPractice(activeProvider);
  activeProvider.on('accountsChanged', changed);
  activeProvider.on('chainChanged', changed);
  activeProvider.on('disconnect', changed);
  await practice.connect();
  element('status').textContent = 'Sepolia의 P 계정에 연결했습니다. 다음은 조건 확인입니다.';
}));
function changed() { reset('계정 또는 체인 연결이 바뀌었습니다. 조건을 다시 확인하세요.'); }

element('prepare').addEventListener('click', () => run(async () => {
  reset();
  element('status').textContent = '관리자·토큰·재임 번호·nonce를 조회합니다…';
  const data = await practice.prepare(element('nonce').value);
  element('typed-data').textContent = JSON.stringify(data, null, 2);
  element('deadline').textContent = `등록 마감: ${new Date(Number(data.message.deadline) * 1000).toLocaleString('ko-KR')} / ownerEpoch: ${data.message.ownerEpoch} / nonce: ${data.message.nonce}`;
  element('preview').hidden = false;
  element('status').textContent = '서명할 조건을 준비했습니다. 전체 데이터와 주소를 확인하세요. 아직 서명하지 않았습니다.';
}));
element('sign').addEventListener('click', () => run(async () => {
  element('status').textContent = '현재 상태를 다시 확인하고 MetaMask 서명을 요청합니다. 지갑에서 직접 확인하세요.';
  result = await practice.sign();
  element('download').hidden = false;
  element('status').textContent = 'P의 서명과 계약의 승인 해시가 일치합니다. JSON을 저장해 B에게 전달하세요. 토큰 승인·일정 등록은 아직 하지 않았습니다.';
}));
element('download').addEventListener('click', () => {
  if (!result) return;
  const url = URL.createObjectURL(new Blob([JSON.stringify(result, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = 'vesting-authorization.json';
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
