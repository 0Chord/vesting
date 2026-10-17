# MetaMask로 서명 등록 실습하기

관리자 P가 지급 조건에 서명하고 수령자 B가 등록·청구하는 과정을 실제 지갑으로 확인한다. 구현 명세는 [#20](https://github.com/0Chord/vesting/issues/20), 실습 작업은 [#23](https://github.com/0Chord/vesting/issues/23)이다. 지갑 서명은 사용자가 직접 한다.

## 먼저 이해할 세 가지

1. **approve**: P가 토큰 계약에 “Vesting이 내 MTK를 최대 100개 가져가도 된다”고 기록한다. 수령자는 이 승인에 포함되지 않는다.
2. **지급 조건 서명**: P가 “이 Vesting에서 B에게 100 MTK, cliff 120초·전체 600초”에 서명한다. 아직 예치나 일정 생성은 없다.
3. **B의 등록**: B가 조건과 서명을 제출한다. 성공한 거래 안에서 P의 100 MTK 예치, nonce 사용 처리, 일정 생성이 함께 일어나며 그 블록 시각부터 지급 시간이 흐른다.

서명 요청을 취소하면 새 서명 결과가 생기지 않는다. 등록 거래가 실패하면 그 거래 안의 예치·일정·nonce 변경은 함께 되돌아간다. 앞선 별개 approve 거래는 유지된다. 계정·체인·nonce 입력이 바뀌면 화면의 미리보기와 기존 서명 결과를 버리고 새 조건을 확인한다.

전체 순서: **배포 → 조건 확인·서명 → MTK 준비·approve → B의 등록 → 청구**. MTK 준비·approve를 서명 전에 해도 된다. 각 단계는 별개의 사용자 행동이다.

## 코드는 이 순서로 읽기

| 파일 | 먼저 볼 함수와 역할 |
| --- | --- |
| [`typed-data.mjs`](../script/signature-practice/typed-data.mjs) | `buildTypedData`: 서명할 조건을 JSON으로 구성 |
| [`wallet.mjs`](../script/signature-practice/wallet.mjs) | `prepare`: 현재 상태를 조회하고 마감·epoch를 넣어 조건 확정 |
| 같은 파일 | `sign`: 미리 본 JSON을 서명 요청하고 서명자 확인. `eth_sendTransaction`은 호출하지 않음 |
| [`app.mjs`](../script/signature-practice/app.mjs) | 세 버튼을 위 함수에 연결하고 결과 표시·파일 저장 |
| [`serve.mjs`](../script/signature-practice/serve.mjs) | 로컬 화면 파일 제공 |

`provider.request`는 지갑에 요청을 전달하는 창구다. `eth_accounts`는 연결 계정 조회, `eth_call`은 체인 상태를 바꾸지 않는 계약 실행, `eth_signTypedData_v4`는 메시지 서명 요청이다. Solidity 함수 호출이 필요한 `eth_call`의 앞 4바이트는 함수 식별자이며 뒤에 32바이트 단위 인수가 붙는다. `wallet.mjs`의 `word`와 `addressWord`는 여기서 쓰는 고정 크기 인수를 채운다. 범용 ABI 인코더는 아니다.

<details>
<summary>대표 테스트 세 개를 따라 읽기</summary>

| 준비 → 실행 | 실제 검증하는 결과 | 테스트 |
| --- | --- | --- |
| 100 MTK 조건을 준비하고 화면용 사본을 1로 바꿈 → 서명 요청 | 지갑에는 원래 100 MTK JSON이 전달됨. 미리보기와 실제 승인 내용의 분리를 확인 | [wallet.test.mjs](../test/signature-practice/wallet.test.mjs)의 첫 테스트 |
| 조건 확인 후 계정·epoch·nonce 사용 상태를 바꿈 → 서명 요청 | 요청이 거절되고 eth_signTypedData_v4를 호출하지 않음 | 같은 파일의 두 번째 테스트 |
| 서명 요청 중 계정이나 epoch를 바꿈 → 지갑 응답 도착 | 오래된 결과를 반환하지 않고 조건 재확인을 요구 | 같은 파일의 네 번째 테스트 |

이 테스트에서 RPC 응답은 시험 대역이다. 실제 MetaMask 서명은 사용자 실습에서, 암호 복구와 필드 변조는 독립 검토의 EVM 실행에서 별도로 확인했다. 두 검사를 같은 증거로 세지 않는다.

</details>

## 이번 배포에서 확인한 것

2026-10-17에 [새 Vesting](https://sepolia.etherscan.io/address/0x2ce49c26cde36e861922e313dbae004583e628be)을 배포했다. [배포 거래](https://sepolia.etherscan.io/tx/0x0e387d2627c86aa1d26ffcca77344d1d623f485fa82f41afbbcbfd1ca7feb7d1)는 블록 11932677에서 성공했다. 제공자는 P, TOKEN은 앞선 실습의 MTK다. 최초 조회에서 ownerEpoch=1, nextScheduleId=0을 확인했다.

생성 거래의 입력은 아래 소스·설정으로 빌드한 생성 코드와 생성자 인수에 일치했다. 런타임 코드도 생성자가 넣는 immutable 위치를 제외하고 빌드 결과와 일치했다. 이는 로컬 코드 대조 결과이며 Etherscan 소스 검증을 제출했다는 뜻은 아니다.

서명 도메인은 `name=Vesting`, `version=1`, `chainId=11155111`, `verifyingContract=새 Vesting 주소`다. 도메인이 다른 계약의 서명을 새 계약에 가져오는 것을 막는다.

<details>
<summary>1. 새 Vesting 배포를 재현하려면</summary>

## 1. 서명을 검증할 새 Vesting 배포

기존 Sepolia Vesting에는 서명 등록 함수가 없다. GitHub에서 코드를 병합해도 이미 배포된 계약의 코드는 바뀌지 않는다. 새 Vesting을 배포하고 기존 시험용 MTK 계약을 연결한다.

배포 대상 소스는 #21이 병합된 `b69f87f65be53c36c2ecb1ff73ea9c9a20493f6e`다. 아래 명령은 이 소스와 submodule을 준비한 저장소 루트에서 실행한다. 실습 문서·도구 변경이 배포할 계약 소스를 바꾸지는 않는다.

먼저 변수를 설정한다. 아래 P와 TOKEN은 앞선 실습에 사용한 공개 테스트 주소다. 다른 사람이 실행할 때는 자신의 P와 시험용 토큰으로 바꾼다.

```bash
SEPOLIA_RPC_URL=https://rpc.sepolia.ethpandaops.io
PROVIDER=0x2E8B51228117B9f2916ad9dC254522F8786A4C2E
TOKEN=0x7e61a37fce010ad620b052273d23efe5dc94bba8

cast chain-id --rpc-url "$SEPOLIA_RPC_URL"
cast balance "$PROVIDER" --ether --rpc-url "$SEPOLIA_RPC_URL"
```

chain ID는 `11155111`이어야 한다. MetaMask에서도 Sepolia와 P를 선택한다. P의 Sepolia ETH는 배포 거래의 가스비로 사용된다. 이 단계에는 MTK 예치가 없다.

```bash
forge create src/Vesting.sol:Vesting \
  --use 0.8.33 --evm-version prague --optimize false --optimizer-runs 200 \
  --rpc-url "$SEPOLIA_RPC_URL" --from "$PROVIDER" \
  --browser --broadcast \
  --constructor-args "$TOKEN" "$PROVIDER"
```

이 명령이 하는 일은 한 가지다. `Vesting(TOKEN, PROVIDER)`를 생성하는 거래를 준비하고, 사용자가 MetaMask에서 확인·서명하면 Sepolia에 전송한다. 생성자 인수는 토큰 주소와 초기 관리자 주소다. 여기에는 수령자·지급량·cliff·기간이 없다. 일정 생성과 지급 조건 메시지 서명은 뒤에서 별도로 한다.

현재 확인한 도구는 Foundry v1.7.0이며 표시 버전은 `1.6.0-v1.7.0`이다. MetaMask가 설치된 브라우저에서 연결 페이지를 연다. Foundry의 연결 화면에 표시된 지갑 주소가 P인지 확인한다.

배포 성공 결과에서 새 `contractAddress`와 `transactionHash`를 보관한다. 기존 Vesting 주소를 새 주소로 착각하지 않도록 이번 결과에서 가져온다.

```bash
VESTING='<이번 배포의 contractAddress>'
VESTING_TX='<이번 배포의 transactionHash>'

cast receipt "$VESTING_TX" --rpc-url "$SEPOLIA_RPC_URL"
cast code "$VESTING" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$VESTING" 'owner()(address)' --rpc-url "$SEPOLIA_RPC_URL"
cast call "$VESTING" 'TOKEN()(address)' --rpc-url "$SEPOLIA_RPC_URL"
cast call "$VESTING" 'ownerEpoch()(uint256)' --rpc-url "$SEPOLIA_RPC_URL"
cast call "$VESTING" 'nextScheduleId()(uint256)' --rpc-url "$SEPOLIA_RPC_URL"
```

이 단계의 기대 결과는 receipt 성공, 배포 코드 존재, owner=P, TOKEN=지정 MTK, ownerEpoch=1, nextScheduleId=0이다. 브라우저 연결만 성공했거나 거래가 거절·실패했으면 배포 완료로 기록하지 않는다. 실패 원인을 확인하기 전에 같은 배포를 반복하지 않는다.

이 단계에서 설명할 것: **왜 새 Vesting은 생겼는데 수령자 B의 일정과 토큰은 아직 없는가?** 생성자는 계약을 준비하며 일정을 생성하지 않기 때문이다.

</details>

## 2. 서명할 조건 만들기

지금 읽을 코드는 [`buildTypedData`](../script/signature-practice/typed-data.mjs)다. 승인 조건을 MetaMask가 읽을 JSON으로 만들며 지갑 연결·서명·토큰 전송은 하지 않는다. 서명이 붙기 전 데이터이므로 이 결과를 만들었다고 nonce가 사용 처리되는 것도 아니다.

반환값은 `domain`(어느 계약·체인에서 쓸지), `types`(필드 이름·순서·타입), `message`(실제 지급 조건), `primaryType`(서명할 구조체 이름)이다. 이 네 부분이 실제 서명 요청의 입력이 된다.

| 필드 | 이번 실습에서 의미하는 값 |
| --- | --- |
| funder / beneficiary | 토큰을 제공할 P / 등록하고 받을 B |
| totalAmount | 18자리 MTK 100개의 최소 단위인 문자열 `100000000000000000000` |
| cliffDuration / duration | `120`초 / 전체 `600`초. cliff도 전체 기간에 포함 |
| nonce | 미사용 승인 번호. 일정 ID와는 다름 |
| deadline | 등록 마감의 Unix 초. 조건을 조회한 블록 시각에 3600초를 더한 값 |
| ownerEpoch | 현재 조회한 관리자 재임 번호 `1` |

정수는 JavaScript Number 대신 십진 문자열로 전달한다. 100 MTK의 최소 단위 수량이 Number의 안전한 정수 범위보다 크기 때문이다. 이 함수는 형식·정수 범위·지급 조건을 검사하지만 현재 관리자, 만료·nonce 사용 여부까지 보장하지는 않는다.

[`typed-data.test.mjs`](../test/signature-practice/typed-data.test.mjs)는 실제 메시지 형식, 반올림 입력·범위 초과·잘못된 지급 조건의 거절, 여러 메시지 사이의 독립성을 확인한다. 테스트의 고정 deadline은 형식 검사 예시이며 그대로 실제 서명을 요청하는 설정 파일이 아니다.

예시 메시지의 해시를 Cast의 ABI 인코딩·keccak으로 별도 계산한 값과 새 배포 계약의 `hashScheduleAuthorization` 결과가 일치했다. 이 검사는 JSON과 계약 해시의 연결을 확인한다. 실제 지갑 실습 기록은 문서 끝에 별도로 남긴다.

```bash
node --test test/signature-practice/typed-data.test.mjs
```

## 3. 로컬 화면에서 P가 서명하기

Node.js 22 이상과 MetaMask가 설치된 Chrome을 사용한다. 추가 패키지 설치는 없다. 이 브랜치의 저장소 루트에서 실행한다.

```bash
node script/signature-practice/serve.mjs
```

Chrome에서 <http://127.0.0.1:4173>을 연다. 서버는 이 주소에서 화면·JavaScript 네 파일만 제공한다. 지갑 키를 받거나 서명 파일을 저장하는 서버 기능은 없다. 종료는 실행한 터미널에서 Ctrl+C다.

1. MetaMask에서 Sepolia와 **P (`0x2e8b…4c2e`)**를 선택하고 **지갑 연결**을 누른다. B의 계정은 아직 사용하지 않는다.
2. 미사용 nonce를 입력하고 **현재 상태 조회 · 조건 확인**을 누른다. 아래 실행 기록의 `7`은 이미 사용했으므로 재실습할 때는 다른 미사용 번호를 고른다.
3. 전체 데이터를 펼쳐 새 Vesting 주소, P·B, 100 MTK, cliff 120초, 전체 600초, nonce, ownerEpoch, 등록 마감을 읽는다. 마감은 조회한 블록 시각부터 한 시간이다. 다시 조회하면 새 마감이 생긴다.
4. 조건을 확인했으면 **이 조건으로 서명 요청**을 누르고 MetaMask에서 직접 확인·서명한다. 이 버튼은 `eth_signTypedData_v4`를 사용한다. [MetaMask 공식 서명 설명](https://docs.metamask.io/metamask-connect/evm/guides/sign-data/).
5. 화면에 P의 서명 확인 결과가 나오면 **조건 + 서명 JSON 저장**을 누른다. 파일에는 `typedData`와 `signature`가 담긴다. 이 파일은 등록할 B에게 전달하며 미사용 서명을 GitHub에 올리지 않는다.

계정·체인·nonce 입력이 바뀌면 미리보기와 서명 결과를 폐기한다. 서명 요청 전후에 관리자·ownerEpoch·미사용 nonce·등록 마감을 다시 검사한다. 서명 거절이나 RPC 실패 후에도 조건 확인부터 다시 시작한다. 페이지 새로고침·종료 시 결과는 사라지므로 필요한 파일은 직접 저장한다.

P의 서명 여부는 계약의 `hashScheduleAuthorization` 결과와 EVM의 `ecrecover` 조회로 확인한다. 이 예제는 MetaMask의 EOA 서명을 대상으로 한다. 계약 지갑의 ERC-1271 UI는 포함하지 않는다. 이 확인 시점 뒤에 관리자 변경·다른 등록·마감 경과가 생길 수 있으므로 실제 등록 성공 여부는 B의 거래 영수증과 상태로 확인해야 한다.

서명 자체에는 가스비·MTK 전송이 없다. P의 MTK 잔고가 0이거나 아직 approve하지 않았어도 서명은 만들 수 있다. B가 등록할 때는 P의 잔고와 새 Vesting에 대한 allowance가 충분해야 한다.

## 4. P의 토큰 준비와 approve

아래 변수는 기존 실습 주소다. 자신의 배포를 쓰면 `wallet.mjs`의 `DEPLOYMENT`와 함께 바꾼다. `jq`는 다음 단계에서 JSON을 읽는 명령이며 `jq --version`으로 설치 여부를 확인한다.

```bash
SEPOLIA_RPC_URL=https://rpc.sepolia.ethpandaops.io
TOKEN=0x7e61a37fce010ad620b052273d23efe5dc94bba8
VESTING=0x2ce49c26cde36e861922e313dbae004583e628be
PROVIDER=0x2E8B51228117B9f2916ad9dC254522F8786A4C2E
BENEFICIARY=0x4ee3E1BF5E788C0F844fA9e5A8FbDA16AD421d69
AMOUNT=100000000000000000000

cast call "$TOKEN" 'balanceOf(address)(uint256)' "$PROVIDER" --rpc-url "$SEPOLIA_RPC_URL"
```

MetaMask에서 P와 Sepolia를 선택한다. P의 잔고가 부족할 때만 시험용 MTK를 mint한다. 이 토큰의 `mint`는 누구나 호출할 수 있는 실습 기능이다.

```bash
cast send "$TOKEN" 'mint(address,uint256)' "$PROVIDER" "$AMOUNT" \
  --rpc-url "$SEPOLIA_RPC_URL" --from "$PROVIDER" --browser
```

mint 성공과 P 잔고를 확인한 뒤 새 Vesting에 100 MTK의 사용 한도를 준다.

```bash
cast send "$TOKEN" 'approve(address,uint256)' "$VESTING" "$AMOUNT" \
  --rpc-url "$SEPOLIA_RPC_URL" --from "$PROVIDER" --browser

cast call "$TOKEN" 'allowance(address,address)(uint256)' "$PROVIDER" "$VESTING" \
  --rpc-url "$SEPOLIA_RPC_URL"
```

## 5. B가 서명 파일을 읽어 등록하기

MetaMask에서 B와 Sepolia를 선택한다. Foundry 연결 화면의 실제 연결 계정도 B여야 한다. 아래 `--from` 옵션만으로 MetaMask의 선택 계정이 바뀌지는 않는다. 등록 가스비는 B의 Sepolia ETH로 낸다.

`AUTH_FILE`은 방금 저장한 승인 파일의 실제 경로로 맞춘다. 재실습하면 Chrome이 `vesting-authorization (1).json`처럼 다른 이름으로 저장할 수 있다. 이전 파일을 다시 읽지 않도록 아래 조회의 nonce·마감·주소가 방금 확인한 조건과 같은지 읽는다. 이 조회는 서명 원문을 출력하지 않는다.

```bash
AUTH_FILE="$HOME/Downloads/vesting-authorization.json"
jq '{domain: .typedData.domain, message: .typedData.message}' "$AUTH_FILE"
AUTHORIZATION=$(jq -r '
  .typedData.message |
  [.funder, .beneficiary, .totalAmount, .cliffDuration,
   .duration, .nonce, .deadline, .ownerEpoch] |
  "(" + join(",") + ")"
' "$AUTH_FILE")
SIGNATURE=$(jq -r '.signature' "$AUTH_FILE")
```

`AUTHORIZATION`은 계약 함수의 첫 인수인 구조체 묶음이고 `SIGNATURE`는 두 번째 인수다. 파일의 domain 주소가 위 VESTING과 같고 funder·beneficiary·금액·기간이 의도한 조건인지 확인한다. 파일 안의 조건을 수정하면 P의 서명을 다시 받아야 한다. 이 화면은 기본 100 MTK 조건을 만든다.

먼저 B를 호출자로 삼아 상태를 바꾸지 않는 `cast call`로 등록을 검사한다.

```bash
REGISTER='createScheduleWithSignature((address,address,uint256,uint64,uint64,uint256,uint256,uint256),bytes)(uint256)'
cast call "$VESTING" "$REGISTER" "$AUTHORIZATION" "$SIGNATURE" \
  --rpc-url "$SEPOLIA_RPC_URL" --from "$BENEFICIARY"
```

성공하면 예상 일정 ID가 나온다. 이 조회로 실제 일정이나 예치가 생기지는 않는다. 같은 조건으로 실제 거래를 보내고 receipt 성공을 확인한다.

```bash
cast send "$VESTING" "$REGISTER" "$AUTHORIZATION" "$SIGNATURE" \
  --rpc-url "$SEPOLIA_RPC_URL" --from "$BENEFICIARY" --browser
```

첫 등록은 일정 ID 0이다. 이후 실습은 receipt의 `ScheduleCreated` / `ScheduleAuthorizationUsed` 이벤트에서 실제 ID를 읽는다. `nonce`는 일정 ID와 다르다. 실패했다면 원인을 먼저 확인한다. 여전히 유효한 미사용 승인이라면 잔고·allowance를 보완해 같은 서명으로 재시도할 수 있다.

## 6. 조회·청구·중복 거절 확인

아래 자리에는 방금 성공한 등록 receipt의 `ScheduleCreated` 이벤트에서 확인한 숫자 ID를 넣는다. 이 문서의 완료 기록은 ID 0이지만, 같은 배포에서 새 nonce로 재실습하면 ID가 1 이상이 될 수 있다. 이전 일정 ID를 그대로 복사하지 않는다.

```bash
SCHEDULE_ID='<이번 등록 receipt에서 확인한 숫자 ID>'
cast call "$VESTING" 'getSchedule(uint256)((address,address,uint256,uint256,uint64,uint64,uint64,uint64,bool))' \
  "$SCHEDULE_ID" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$VESTING" 'releasableAmount(uint256)(uint256)' "$SCHEDULE_ID" --rpc-url "$SEPOLIA_RPC_URL"
```

cliff 전에는 0이다. 받을 금액이 생긴 뒤 B가 직접 청구한다. 실제 지급량은 조회 때의 값이 아니라 청구가 성공한 블록 시각으로 결정된다. 테스트넷은 실제 블록 시각을 기다리며 `vm.warp`로 시간을 옮기지 않는다.

```bash
cast send "$VESTING" 'claim(uint256)' "$SCHEDULE_ID" \
  --rpc-url "$SEPOLIA_RPC_URL" --from "$BENEFICIARY" --browser
```

전체 600초가 지나면 남은 양을 같은 함수로 청구한다. 만기 청구 후에는 일정의 claimedAmount가 totalAmount와 같고 releasableAmount가 0이어야 한다. 기존에 B가 받은 MTK가 있으면 지갑의 전체 잔고와 이번 일정의 수령량을 구분한다.

사용한 승인으로 위 `cast call` 등록 검사를 다시 하면, 등록 마감 전에는 `AuthorizationAlreadyUsed`로 거절된다. 마감 뒤에는 코드의 검사 순서상 `AuthorizationExpired`가 먼저 나온다. 중복 실패 확인에 실제 거래를 보내거나 가스비를 쓸 필요는 없다.

| 단계 | P 잔고 | Vesting 잔고 | B 잔고 | allowance |
| --- | ---: | ---: | ---: | ---: |
| 이번 mint 전 | 0 | 0 | 100 (이전 실습분) | 0 |
| 100 MTK mint | 100 | 0 | 100 | 0 |
| approve | 100 | 0 | 100 | 100 |
| B의 일정 0 등록 | 0 | 100 | 100 | 0 |
| 첫 청구 46 MTK | 0 | 54 | 146 | 0 |
| 만기 잔여 54 MTK 청구 | 0 | 0 | 200 | 0 |

`cast call`과 각 거래 전후 `balanceOf`·`allowance`·일정 조회로 대조한다. 외부에서 직접 전송한 토큰이나 다른 일정이 추가되면 이 표와 같은 계약 전체 잔고를 기대하지 않는다.

## 검증과 실제 실행 기록

```bash
node --test test/signature-practice/*.test.mjs
```

검사 10개는 조건의 정수 정밀도·범위, 미리보기 보존, 잘못된 체인·계정·관리자·epoch·사용 nonce·만료의 거절, 서명 대기 중 변경과 지갑 거절·잘못된 서명자의 결과 폐기를 검증한다. `wallet.test.mjs`는 지갑 RPC 응답을 대체하므로 실제 암호 검증과 구분한다. 같은 명령을 필수 `Foundry project` CI 작업에 연결했다. 원격 CI 결과는 게시한 커밋에서 확인한다.

별도 컨텍스트의 검토자는 고정 snapshot에서 버튼·이벤트 연결, ABI 인코딩, 합성 키의 실제 EVM 서명 복구, 승인 8필드·domain 4필드 변조 거절, HTTP 제공 범위를 검사했다. 이 로컬 검토에서 확인된 결함은 없었다. 실제 MetaMask 실습은 아래 공개 거래와 상태로 별도 확인한다.

- [배포](https://sepolia.etherscan.io/tx/0x0e387d2627c86aa1d26ffcca77344d1d623f485fa82f41afbbcbfd1ca7feb7d1): 블록 11932677. 소스·컴파일 설정과 초기 상태는 [실행 기록](../deployments/sepolia-signature-practice.json)에 남긴다.
- [100 MTK mint](https://sepolia.etherscan.io/tx/0xc1c12028f7aa23c79d375add229e19c2e8c58f87a0d74a16bf344e71268aabe3), [100 MTK approve](https://sepolia.etherscan.io/tx/0xabb332223199761edfe915969f4f6f333ae3191057585ca8ccaf048fe7a8882b).
- [B의 등록](https://sepolia.etherscan.io/tx/0x82ec039633be48dc155956484eb545b851ece5b71b594b0276fc88a3d967afea): 일정 0, nonce 7·epoch 1, 시작 시각 1792223220. cliff 종료 1792223340, 전체 종료 1792223820.
- [첫 청구](https://sepolia.etherscan.io/tx/0x3e8dddd28492a6fa258766695d3093108569ae916e71d66ca0a2b6fad9e106ee): 블록 11932850, 등록 276초 뒤에 46 MTK 수령. 조회했던 34 MTK와 청구 때의 양이 다른 이유는 블록 시각이 달라졌기 때문이다.
- 사용한 승인의 읽기 전용 재등록 호출에서 `AuthorizationAlreadyUsed`의 revert selector `0x73104ede`를 확인했다.
- [만기 잔여 청구](https://sepolia.etherscan.io/tx/0x61a4e85a3de6bd27aec31674c0d5571b42ea5f5affebad110afa734db60535f6): 블록 11932890, 시각 1792224012에 54 MTK 수령. 이 블록에서 claimedAmount=100 MTK, releasableAmount=0, Vesting 잔고=0을 확인했다. B 지갑의 총 200 MTK 중 이번 일정분은 100 MTK다.

개인키·시드·서명 원문·개인 학습 문답은 실행 기록에 포함하지 않는다. Etherscan 소스 검증과 로컬 bytecode 대조는 구분한다. 새 계약의 Etherscan 소스 검증 제출은 이 기록에서 확인하지 않았다.
