# Sepolia 배포와 소스 검증

MetaMask에서 직접 서명해 **시험용 토큰 → Vesting** 순서로 배포한 기록과 실행 안내입니다. [학습 #17](https://github.com/0Chord/vesting/issues/17)의 범위는 배포·초기 상태 확인·소스 검증까지입니다.

먼저 이해할 것은 세 가지입니다.

1. 토큰 계약은 잔고를 관리하고, Vesting 계약은 그 토큰의 지급 일정을 관리합니다. 배포 후에도 토큰을 발행하거나 예치하기 전 잔고는 0입니다.
2. 두 배포는 별개 거래입니다. 두 번째 배포를 거절해도 첫 번째 계약은 체인에 남습니다.
3. 소스 검증은 공개 소스·컴파일 설정과 배포 코드의 대응을 확인합니다. 지급 기능의 테스트나 보안 감사와는 검증 범위가 다릅니다.

**읽기 순서:** [실제 결과](#실제-결과) → [기존 배포 조회](#기존-배포-조회). 직접 새로 배포할 때만 아래의 접힌 실행 절차를 펼칩니다.

## 실제 결과

2026-10-16 UTC 기준이며, 자세한 값은 [배포 기록 JSON](../deployments/sepolia.json)에 있습니다.

| 항목 | 결과 |
| --- | --- |
| 네트워크 | Sepolia · chain ID `11155111` |
| 배포자·초기 관리자 | `0x2e8b51228117b9f2916ad9dc254522f8786a4c2e` |
| 시험용 토큰 | [0x7e61a37fce010ad620b052273d23efe5dc94bba8](https://sepolia.etherscan.io/address/0x7e61a37fce010ad620b052273d23efe5dc94bba8#code) · Mock Token / MTK / 18 decimals |
| Vesting | [0xa7894b86bdd8851303212c2fccc24d03fd34baff](https://sepolia.etherscan.io/address/0xa7894b86bdd8851303212c2fccc24d03fd34baff#code) |
| 토큰 배포 거래 | [성공 receipt](https://sepolia.etherscan.io/tx/0x0c45731bc7c5d8b15bde1b07caff30982cb456c5508eb0c2a9650101072192b1) · 블록 `11927046` · 11:27:00 UTC |
| Vesting 배포 거래 | [성공 receipt](https://sepolia.etherscan.io/tx/0x24bf153a70c4e1d65a7110d6ac059876ee6cb9a38eeef8302d3189840b1aa2a2) · 블록 `11927056` · 11:29:24 UTC |
| 초기 상태 | 블록 `11927056`에서 owner·TOKEN 일치, 총공급량·제공자/계약 토큰 잔고·일정 수 모두 `0` |
| 소스 검증 | 두 계약 모두 Etherscan `Pass - Verified` |

이 값들은 위 블록의 관측 기록입니다. 누구나 호출할 수 있는 MockERC20의 `mint`나 이후 거래에 따라 현재 상태는 달라질 수 있습니다. 소스·생성자 인자와 실제 배포 거래 입력도 대조했습니다. Vesting 실행 코드의 immutable TOKEN 자리에는 실제 토큰 주소를 반영해 비교했습니다.

## 기존 배포 조회

아래는 이미 배포된 계약을 조회하는 명령입니다. 가스비와 MetaMask 서명이 필요 없습니다. Bash·Zsh의 같은 터미널에서 실행합니다.

```bash
SEPOLIA_RPC_URL=https://rpc.sepolia.ethpandaops.io
DEPLOYER=0x2e8b51228117b9f2916ad9dc254522f8786a4c2e
TOKEN=0x7e61a37fce010ad620b052273d23efe5dc94bba8
VESTING=0xa7894b86bdd8851303212c2fccc24d03fd34baff
```

접속한 체인 번호는 `11155111`이어야 합니다. 배포 코드 크기는 각각 `3734`, `7184` bytes입니다.

```bash
cast chain-id --rpc-url "$SEPOLIA_RPC_URL"
cast codesize "$TOKEN" --rpc-url "$SEPOLIA_RPC_URL"
cast codesize "$VESTING" --rpc-url "$SEPOLIA_RPC_URL"
```

초기 상태를 다시 읽으려면 Vesting 배포 블록을 지정합니다. 출력 순서는 관리자 주소 → 토큰 주소 → 일정 수 `0`입니다.

```bash
cast call "$VESTING" 'owner()(address)' --block 11927056 --rpc-url "$SEPOLIA_RPC_URL"
cast call "$VESTING" 'TOKEN()(address)' --block 11927056 --rpc-url "$SEPOLIA_RPC_URL"
cast call "$VESTING" 'nextScheduleId()(uint256)' --block 11927056 --rpc-url "$SEPOLIA_RPC_URL"
```

다음 세 값은 모두 `0`입니다. ETH 잔고가 아닌 MTK의 정수 최소 단위 잔고입니다. 현재 상태를 보려면 `--block 11927056`을 빼고 조회합니다.

```bash
cast call "$TOKEN" 'totalSupply()(uint256)' --block 11927056 --rpc-url "$SEPOLIA_RPC_URL"
cast call "$TOKEN" 'balanceOf(address)(uint256)' "$DEPLOYER" --block 11927056 --rpc-url "$SEPOLIA_RPC_URL"
cast call "$TOKEN" 'balanceOf(address)(uint256)' "$VESTING" --block 11927056 --rpc-url "$SEPOLIA_RPC_URL"
```

## 새 계약을 배포할 때

<details>
<summary>준비 → 토큰 배포 → Vesting 배포 → 연결 확인</summary>

### 1. 소스와 도구 준비

실제 배포한 소스는 [dad06fc1e6a031f3ab7fcd9e53c635620822d7e9](https://github.com/0Chord/vesting/commit/dad06fc1e6a031f3ab7fcd9e53c635620822d7e9)입니다. 같은 코드를 재현하려면 별도 checkout에서 이 커밋과 submodule을 맞춥니다. 아래 예시는 새 디렉터리를 만듭니다.

```bash
git clone https://github.com/0Chord/vesting.git vesting-sepolia
cd vesting-sepolia
git switch --detach dad06fc1e6a031f3ab7fcd9e53c635620822d7e9
git submodule update --init --recursive
```

브라우저 지갑 배포는 Foundry 릴리스 **v1.7.0**에서 확인했습니다. 해당 바이너리의 표시 버전은 `1.6.0-v1.7.0`, 커밋은 `f83bad9`입니다. 1.5.1에서는 `--browser` 옵션이 보여도 `forge create` 실행이 실패했습니다.

```bash
foundryup --install v1.7.0
forge --version
```

Zsh에서 이전 실행 파일이 선택되면 `rehash` 후 다시 확인합니다. 다른 도구 버전을 사용할 때도 아래 빌드 설정을 유지합니다. v1.7.0의 기본 EVM은 Osaka이므로 **배포·검증 양쪽에서 Prague를 명시**합니다.

| 빌드 항목 | 실제 사용 값 |
| --- | --- |
| solc | `0.8.33+commit.64118f21` |
| EVM | `prague` |
| optimizer | `false`, runs `200` |
| viaIR | `false` |
| 의존성 | 소스 커밋에 고정된 forge-std·OpenZeppelin submodule revision |

### 2. 네트워크와 본인 계정 확인

`DEPLOYER`를 **직접 서명할 MetaMask 테스트 계정 주소**로 바꿉니다. 위 공개 배포 기록의 주소는 기존 결과를 조회하기 위한 값입니다.

```bash
SEPOLIA_RPC_URL=https://rpc.sepolia.ethpandaops.io
DEPLOYER='<본인의 MetaMask 테스트 계정 주소>'
export FOUNDRY_OPTIMIZER=false FOUNDRY_OPTIMIZER_RUNS=200 FOUNDRY_VIA_IR=false
cast chain-id --rpc-url "$SEPOLIA_RPC_URL"
cast balance "$DEPLOYER" --ether --rpc-url "$SEPOLIA_RPC_URL"
```

chain ID `11155111`과 가스비를 낼 Sepolia ETH를 확인합니다. MetaMask에서도 Sepolia·같은 계정을 선택합니다. ETH는 각 거래의 가스비이며 시간이 흐르는 동안 계속 차감되는 유지비는 아닙니다.

### 3. 토큰 계약 한 개 배포

```bash
forge create test/mocks/MockERC20.sol:MockERC20 \
  --use 0.8.33 --evm-version prague --optimize false --optimizer-runs 200 \
  --rpc-url "$SEPOLIA_RPC_URL" --from "$DEPLOYER" \
  --browser --broadcast
```

`forge create`는 생성 거래를 준비하고, `--browser`는 MetaMask로 서명하며, `--broadcast`는 서명된 거래를 전송합니다. 연결 페이지는 MetaMask가 있는 브라우저에서 엽니다. 기본 브라우저가 다르면 `--browser-disable-open`을 추가하고 CLI에 표시된 로컬 연결 URL을 직접 엽니다. 연결 페이지의 포트가 사용 중이면 `--browser-port`로 별도 포트를 선택합니다.

MetaMask의 네트워크·계정·계약 생성 요청·가스비를 읽고 승인합니다. ETH 전송 값은 `0`이며 가스비는 별도입니다. 연결 성공과 거래 승인은 다른 단계입니다.

성공 receipt의 `contractAddress`와 `transactionHash`를 보관합니다. 이 단계는 토큰 계약 생성이며 `mint`를 호출하지 않습니다.

```bash
TOKEN='<이번 토큰 배포 receipt의 contractAddress>'
TOKEN_TX='<이번 토큰 배포 receipt의 transactionHash>'
cast receipt "$TOKEN_TX" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$TOKEN" 'name()(string)' --rpc-url "$SEPOLIA_RPC_URL"
cast call "$TOKEN" 'symbol()(string)' --rpc-url "$SEPOLIA_RPC_URL"
cast call "$TOKEN" 'decimals()(uint8)' --rpc-url "$SEPOLIA_RPC_URL"
cast call "$TOKEN" 'totalSupply()(uint256)' --rpc-url "$SEPOLIA_RPC_URL"
```

receipt가 성공이고 해당 주소에 코드가 있으며 이름 `Mock Token`·심볼 `MTK`·decimals `18`·공급량 `0`인지 확인합니다. 실제 주소를 확인한 뒤 다음 단계로 이동합니다.

### 4. Vesting 계약 한 개 배포

```bash
forge create src/Vesting.sol:Vesting \
  --use 0.8.33 --evm-version prague --optimize false --optimizer-runs 200 \
  --rpc-url "$SEPOLIA_RPC_URL" --from "$DEPLOYER" \
  --browser --broadcast \
  --constructor-args "$TOKEN" "$DEPLOYER"
```

생성자 인자는 **사용할 토큰 주소 → 초기 관리자 주소** 순서입니다. 토큰 배포와 별개로 MetaMask에서 다시 승인합니다. 성공 receipt를 보관하고 `VESTING`을 이번 `contractAddress`로 바꿉니다.

```bash
VESTING='<이번 Vesting 배포 receipt의 contractAddress>'
VESTING_TX='<이번 Vesting 배포 receipt의 transactionHash>'
cast receipt "$VESTING_TX" --rpc-url "$SEPOLIA_RPC_URL"
```

앞의 조회 절차에서 **기록된 블록 번호를 빼고** 이번 계약의 code·owner·TOKEN·초기 잔고·일정 수를 확인합니다. owner는 본인 계정, TOKEN은 이번 토큰이어야 합니다. 소스 커밋·도구/컴파일 설정·생성자 인자·receipt의 블록과 실제 시각을 이번 실행 기록에 남깁니다. 새 배포는 새 주소와 거래 해시를 만듭니다.

</details>

## Etherscan 소스 검증

<details>
<summary>API 키 입력 → 토큰 검증 → 생성자 인자를 넣어 Vesting 검증</summary>

배포에 사용한 소스·submodule과 같은 설정으로 제출합니다. 검증 대상의 `TOKEN`·`VESTING`·`DEPLOYER` 변수를 먼저 확인합니다. 이 단계는 Etherscan에 소스를 제출하며 온체인 거래나 MetaMask 서명·가스비가 필요 없습니다.

[Etherscan API Keys](https://etherscan.io/myapikey)에서 발급한 키를 **Zsh 터미널에만** 입력합니다. 다음 입력은 화면에 표시되지 않습니다. 키는 문서·공개 결과·Git에 기록하지 않습니다.

```zsh
read -rs "ETHERSCAN_API_KEY?Etherscan API 키 입력: "
export ETHERSCAN_API_KEY
echo
```

토큰은 생성자 인자가 없습니다. `--watch`는 제출 후 최종 결과까지 기다립니다. `--verifier etherscan`으로 검증 대상을 명시합니다.

```bash
FOUNDRY_OPTIMIZER=false FOUNDRY_OPTIMIZER_RUNS=200 FOUNDRY_VIA_IR=false \
forge verify-contract "$TOKEN" test/mocks/MockERC20.sol:MockERC20 \
  --chain sepolia --compiler-version 0.8.33 --evm-version prague \
  --verifier etherscan --watch
```

Vesting은 배포할 때 전달한 토큰·관리자 주소 두 개를 ABI 형식으로 인코딩해 제출합니다. `cast abi-encode`는 이 데이터를 만들 뿐 거래를 전송하지 않습니다.

```bash
CONSTRUCTOR_ARGS=$(cast abi-encode 'constructor(address,address)' "$TOKEN" "$DEPLOYER")
FOUNDRY_OPTIMIZER=false FOUNDRY_OPTIMIZER_RUNS=200 FOUNDRY_VIA_IR=false \
forge verify-contract "$VESTING" src/Vesting.sol:Vesting \
  --chain sepolia --compiler-version 0.8.33 --evm-version prague \
  --constructor-args "$CONSTRUCTOR_ARGS" --verifier etherscan --watch
```

`Submitted`와 `Pending in queue`는 제출·대기 상태입니다. 이번 실행에서는 두 계약 모두 최종 `Pass - Verified`·`Contract successfully verified`를 확인했습니다. 이미 검증된 주소라면 해당 결과를 확인합니다. 현재 관리자와 배포 당시 관리자가 다를 때도 생성자 인자에는 **배포 당시 주소**를 사용합니다.

</details>

## 실패했을 때 어디서 이어가나요?

| 상황 | 확인하고 이어갈 위치 |
| --- | --- |
| `eth_getBalance does not exist/is not available` | 이번 dRPC 접속에서 실제 관측했습니다. 다른 Sepolia RPC로 바꾸고 chain ID와 잔고 조회를 다시 확인합니다. 연결 서버가 바뀌어도 같은 체인의 주소·자산을 사용합니다. |
| `Use send_transaction_via_browser for browser wallets` | Foundry 1.5.1에서 연결 후 관측했습니다. v1.7.0으로 변경하고 성공했습니다. CLI 옵션의 존재만으로 전송 지원을 판단하지 않습니다. |
| 체인·계정이 예상과 다름 | 서명 전에 중단해 RPC·MetaMask·from을 맞춥니다. 자동으로 다른 계정을 선택해 전송하지 않습니다. |
| MetaMask 거절·브라우저 연결 실패 | 거래 hash가 생겼는지 먼저 확인합니다. 전송 여부를 확인하기 전 배포 완료로 기록하지 않습니다. |
| 토큰 성공 후 Vesting 실패 | 첫 토큰 주소·receipt는 보존하고 두 번째 단계에서 재개합니다. |
| 응답 유실·timeout | hash가 있으면 receipt·탐색기를 먼저 확인합니다. pending이면 기다리고, hash가 없으면 계정 거래 목록·nonce도 확인해 전송 여부를 조사합니다. |
| 소스 검증 실패·대기 | 배포는 남습니다. 같은 주소의 소스·compiler·EVM·optimizer·생성자 인자를 대조해 검증을 재개합니다. 재배포로 해결하지 않습니다. |
| 초기 상태가 예상과 다름 | 주소·receipt·입력 소스를 대조하고 오래된 배포 또는 이미 사용된 계약인지 확인합니다. 초기 상태 완료 표시를 보류합니다. |

실제 확인한 범위는 두 배포의 성공·연결/초기 상태·코드 대조·소스 검증, 위의 RPC/구버전 오류와 검증 대기 후 성공입니다. 잘못된 체인·계정, 사용자 거절·부분 성공 후 거절, timeout/재개는 처리 원칙이며 이번 Sepolia 실행에서 의도적으로 재현하지 않았습니다.

토큰 발행 → 승인 → 일정 생성 → 청구·취소는 다음 학습 단위입니다. 이 안내를 읽거나 배포에 성공한 사실만으로 각 지급 규칙의 이해까지 완료됐다고 판정하지 않습니다.

자료: [Foundry v1.7.0 릴리스](https://github.com/foundry-rs/foundry/releases/tag/v1.7.0) · [브라우저 지갑 배포 지원 변경](https://github.com/foundry-rs/foundry/pull/14394) · [Etherscan Foundry 검증](https://docs.etherscan.io/contract-verification/verify-with-foundry)
