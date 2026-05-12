# WNDY 채굴 가이드 (Base mainnet)

Bitcoin이 SHA256 해시 컴페티션이라면, WNDY는 windy-lang esolang 코드의
**실제 실행**을 ZK로 증명해야 발행되는 토큰이다. 이 문서는 직접 코드를
짜서 WNDY를 받기 위한 실무 가이드.

> windy-lang 자체의 문법은 [sisobus/windy](https://github.com/sisobus/windy)
> 참조. 본 문서는 (1) 점수가 어떻게 매겨지는지, (2) 각 Tier를 노릴 때 무엇을
> 최적화하는지, (3) 명령어 흐름만 다룬다. 점수 정책의 *왜*는
> [`PHASE-2-MINING.md`](./PHASE-2-MINING.md)에 있다.

## 컨트랙트 정보 (mainnet)

| 항목 | 값 |
|------|---|
| Windy (WNDY) | `0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca` |
| Minter (V2) | `0xc566ab14616662ae92095a72a8cc23bf62b6ff02` |
| IMAGE_ID | `0xb78810f2e9557907cf9865797240661414e8102326cfdd8d8bc7879d58ca57cb` |
| Verifier (router) | `0x0b144e07a0826182b6b59788c34b32bfa86fb711` |
| RPC | `https://mainnet.base.org` |
| Chain ID | 8453 |
| Explorer | https://basescan.org |

## 1. 사전 준비

| 도구 | 용도 |
|------|------|
| Rust + cargo | guest/host 빌드 (`rustup`) |
| Foundry (`forge`, `cast`) | 트랜잭션 전송 (`foundryup`) |
| Docker Desktop | Risc Zero STARK → Groth16 wrap |
| Base ETH (소량) | mint 트랜잭션 가스 (~0.0001 ETH, $0.05) |

**중요**: `mint()`을 호출하는 주소와 보상 받는 주소(`recipient`)는 달라도 된다.
보상은 proof 안에 commit된 `recipient`로만 간다. 누가 가스 내든 무관.

`circuit/Cargo.lock` 을 절대 건들지 말 것. transitive dep 한 줄만 바뀌어도
`IMAGE_ID`가 달라져서 mainnet verifier가 거부한다.

## 2. Tier 시스템

| Tier | Score range | 보상 | 결과 |
|------|-------------|------|------|
| None | `< 10` | — | `revert ScoreBelowFloor` |
| Bronze | `10 ~ 29` | **0.1 WNDY** | mint 성공 |
| Silver | `30 ~ 69` | **1.0 WNDY** | mint 성공 |
| Gold | `≥ 70` | **10.0 WNDY** | mint 성공 (proof당 cap) |

**하드 필터** (점수 계산 전에 컷):
- `visitedCells` 가 **10 ~ 1500** 범위 (너무 작아도, 너무 커도 거부)
- `program_hash` 가 이전에 채굴된 적이 없어야 함 (first-claim wins, 영구 dedup)
- `nonce` 가 이전에 사용된 적이 없어야 함

## 3. 점수 공식 (간략)

```
core = ⌊log2(maxAliveIps)⌋ × 10         # 한 시점 동시 IP 수 (병렬성)
     + spawnedBonus                     # t-spam 가드 적용 (아래)
     + min(gridWrites,  100) × 0.3      # 그리드 메모리 쓰기
     + min(branchCount, 100) × 0.2      # 분기

diversityFactor = 1 + (사용한 hard opcode 가중치 합) × 5 / 100
                                        # 범위 1.00 ~ 3.05

score = core × diversityFactor
```

**multiplicative diversity의 의미**: `core`가 0이면 어떤 diversity 가중치도 0.
즉 "거대 grid에 hard op만 뿌려놓고 IP는 한 칸씩 지나가게 하는" 가짜 프로그램은
0점이다.

### t-spam 가드

`spawnedDensity = spawnedIps / visitedCells > 0.5` 이면 `spawnedBonus = 0`.

이유: `tttt…@` 같이 SPLIT만 잔뜩 깐 가짜 프로그램은 spawned/visited ≈ 1.0이
나와서 가드에 걸린다. 진짜 timing puzzle은 ratio 0.2~0.4 정도에서 통과한다.

### opcode 가중치 (diversity)

| Opcode | 가중치 | 의미 |
|--------|--------|------|
| `t` | 8 | SPLIT |
| `p` | 8 | grid POP |
| `g` | 6 | grid GET |
| `_` | 4 | wind ↓ |
| `\|` | 4 | wind ↑ |
| `≫` | 3 | wind → |
| `≪` | 3 | wind ← |
| `~` | 2 | RNG |
| `#` | 2 | comment skip |
| `"` | 1 | string mode |

총합 41 → diversityFactor = `1 + 41 × 5/100 = 3.05` (이론 최대).

## 4. 각 Tier 노리는 전략

### Bronze (score 10~29) — 입문

보조 메트릭 하나만 의미 있게 쓰면 충분.

**예시 1**: 그리드 메모리 25회 쓰기 + 분기 10회
- `core = 0 + 0 + 25×0.3 + 10×0.2 = 7.5 + 2.0 = 9.5`
- diversity 3개 (`p`, `g`, `_`) → 가중치 8+6+4=18 → factor = 1.90
- `score = 9.5 × 1.90 ≈ 18` → **Bronze** ✅
- 참고: `fib.wnd` (22.61) / `factorial.wnd` (16.34)

### Silver (score 30~69) — 표준 목표

두 축 이상을 함께 굴려야 함.

**예시 1**: multi-IP 강조 (`puzzle_hard.wnd` 패턴)
- maxAlive 4, spawned 3, visited 15, diversity (`t`) = 8
- `core = log2(4)×10 + 3×1.5 = 20 + 4.5 = 24.5`
- `factor = 1 + 8×5/100 = 1.40`
- `score = 24.5 × 1.40 = 34.30` → **Silver** ✅

**예시 2**: 다축 결합
- maxAlive 2, spawned 1, writes 50, branches 30, diversity (`t`,`p`,`g`,`_`) → 26
- `core = 10 + 1.5 + 15 + 6 = 32.5`
- `factor = 1 + 26×5/100 = 2.30`
- `score = 32.5 × 2.30 = 74.75` → 어 **Gold** 됨 (다축 결합이 강력)

### Gold (score ≥ 70) — 진지한 알고리즘

진짜로 여러 축 사용. 한 메트릭 spam으로는 안 됨.

**예시**: maxAlive 8, spawned 15, writes 80, branches 50, diversity 7개 사용 (35점)
- `core = log2(8)×10 + 15×1.5 + 80×0.3 + 50×0.2 = 30 + 22.5 + 24 + 10 = 86.5`
- `factor = 1 + 35×5/100 = 2.75`
- `score = 86.5 × 2.75 = 237.9` → **Gold** (압도적)

### 절대 안 되는 패턴 (None — 0점)

- 거대 grid에 hard op만 깔기 → core 0 × any factor = 0
- `tttt…@` (t-spam) → spawned bonus 0, 나머지 메트릭도 0
- `hello.wnd` 처럼 문자열 출력만 → 모든 보조 메트릭 0

## 5. 코드 작성 — 실제 흐름

### 5.1 새 .wnd 파일

`circuit/programs/my_first_mine.wnd` 같이 새 파일 작성.

windy-lang 핵심 opcode (간략):
- `t` — SPLIT (IP 복제)
- `p` — POP into grid memory
- `g` — GET from grid memory
- `_`, `|` — wind direction (↓ ↑ ← →)
- `,` — pop & print
- `@` — halt

자세한 건 [sisobus/windy README](https://github.com/sisobus/windy)와
[`circuit/programs/README.md`](../circuit/programs/README.md) 의 sample들 참조.

### 5.2 로컬 dry-run으로 metrics 확인 (Docker 없이)

```bash
cd circuit
RUST_LOG=info cargo run --release -p host -- \
  --recipient 0x0000000000000000000000000000000000000001 \
  --program-file programs/my_first_mine.wnd
```

출력의 `guest journal:` 블록을 본다:

```
guest journal:
  recipient:          0x0000...0001
  nonce:              0x... (random)
  program_hash:       0x...
  output_hash:        0x...
  exit_code:          0 (Ok)
  steps:              ...
  ─ Phase 2 metrics ─
  hard_opcode_bitmap: ... (t p g)
  max_alive_ips:      ...
  spawned_ips:        ...
  grid_writes:        ...
  branch_count:       ...
  visited_cells:      ...
```

이 메트릭으로 §4 공식 직접 계산해서 예상 tier 검증.

### 5.3 (선택) on-chain pre-grading

귀찮으면 mainnet의 `computeScore`를 직접 호출해서 점수만 미리 받아볼 수 있다
(가스 안 든다, view 함수):

```bash
# 14-field WindyJournal을 tuple로 만들어 cast call. 다음 ABI 그대로 사용:
# (address,bytes32,bytes32,bytes32,int32,uint64,uint16,uint64,uint64,uint64,uint64,uint64,uint32,uint32)

cast call 0xc566ab14616662ae92095a72a8cc23bf62b6ff02 \
  "computeScore((address,bytes32,bytes32,bytes32,int32,uint64,uint16,uint64,uint64,uint64,uint64,uint64,uint32,uint32))(uint256,uint8)" \
  "(0x0000...0001, 0x..., 0x..., 0x..., 0, 100, 12, 8, 15, 50, 30, 200, 0, 0)" \
  --rpc-url https://mainnet.base.org
```

리턴값:
- `scoreX1000` — 실제 점수 × 1000 (예: `34300` = score 34.30)
- `tier` — 0=None, 1=Bronze, 2=Silver, 3=Gold

### 5.4 mint용 Groth16 proof 생성

Docker Desktop 켜고 (이건 wrap 컨테이너 실행 필요):

```bash
docker info > /dev/null && echo "✅ Docker running"

cd circuit
cargo run --release -p host -- \
  --recipient 0x<본인 mainnet 주소> \
  --program-file programs/my_first_mine.wnd
```

처음이면 Docker가 `risczero/risc0-groth16-prover` 이미지를 받느라 5~10분 걸림.
이후 캐시되면 1~2분.

마지막에 출력되는 블록:

```
on-chain payload (paste into `cast send`):
  image_id: 0xb78810f2...  ← 위 mainnet IMAGE_ID와 정확히 같아야 함
  selector: 0x73c457ba     ← Risc Zero Groth16 v3.0.0
  seal:     0x...          ← 이거 복사
  journal:  0x...          ← 이거도 복사
```

### 5.5 mainnet에 mint 트랜잭션

```bash
cd ../contracts

export MINTER=0xc566ab14616662ae92095a72a8cc23bf62b6ff02
export BASE_MAINNET_RPC=https://mainnet.base.org
export SEAL=0x<5.4에서 복사한 seal>
export JOURNAL=0x<5.4에서 복사한 journal>

cast send $MINTER \
  "mint(bytes,bytes)" \
  $SEAL $JOURNAL \
  --rpc-url $BASE_MAINNET_RPC \
  --account <your-keystore-account>
```

`status: 1 (success)` 출력되면 채굴 완료.

### 5.6 잔액 확인

```bash
cast call 0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca \
  "balanceOf(address)(uint256)" \
  0x<recipient address> \
  --rpc-url https://mainnet.base.org | xargs -I {} cast --from-wei {}
```

또는 https://basescan.org/token/0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca 에서
"Holders" 탭 → 본인 주소 등장 확인.

## 6. 자주 만나는 오류

| 오류 (revert reason) | 원인 | 해결 |
|----------------------|------|------|
| `VisitedCellsOutOfRange` | 실행 cell 수가 10 미만 또는 1500 초과 | 코드 크기 / 도달 가능 cell 조정 |
| `ScoreBelowFloor(scoreX1000)` | 점수 < 10 | 보조 메트릭 늘리기 (§4 참조) |
| `NonceAlreadyConsumed` | 같은 nonce 사용 이력 있음 | `--nonce` 인자로 새 nonce 지정 (or 생략하면 random) |
| `ProgramAlreadyConsumed` | 같은 program_hash 이미 mint됨 | 코드 한 글자 변경 = 새 program_hash |
| risc0 verifier revert | proof IMAGE_ID 불일치 | `Cargo.lock` 안 깨졌는지 확인, `cargo build --locked` |
| Docker 관련 에러 | Groth16 wrapper 컨테이너 실행 실패 | Docker Desktop 켜기, 재시도 |

### IMAGE_ID 매칭 (가장 흔한 함정)

`circuit/Cargo.lock` 을 삭제하거나 `cargo update` 를 돌리면 transitive dep이
바뀌어서 IMAGE_ID 가 달라진다. mainnet verifier는 정확히
`0xb78810f2e9557907cf9865797240661414e8102326cfdd8d8bc7879d58ca57cb` 만 받으므로
호스트가 출력하는 image_id가 이거와 다르면 verifier가 거부한다.

확인:
```bash
cd circuit
cargo run --release -p host -- --print-image-id
# 0xb78810f2e9557907cf9865797240661414e8102326cfdd8d8bc7879d58ca57cb 와 같아야 함
```

다르면 `git checkout Cargo.lock` 으로 lock 복원 후 `cargo clean && cargo build --locked --release` 재시도.

## 7. first-claim 게임

같은 `program_hash` (= `sha256(.wnd 소스 전체)`) 는 **영구 dedup**. 누가 먼저
mint하면 그 다음 사람들은 같은 코드로 못 받는다.

전략적 함의:
- 알고리즘을 공개 전에 본인이 먼저 채굴하고 공개하는 방식이 자연스러움
- 공백/줄바꿈 한 칸만 바꿔도 다른 program_hash → 사실상 무한 변형 가능하지만,
  변형마다 새 proof 생성 (5~10분) + 가스가 들어감
- Bronze 0.1 WNDY × 다수 변형 vs Gold 10 WNDY × 진지한 알고리즘 한 번의
  tradeoff를 본인 컴퓨팅 비용과 비교해 고민

## 8. 다음 단계 (참고)

- 점수 정책 *왜*: [`PHASE-2-MINING.md`](./PHASE-2-MINING.md)
- 공급 곡선 / tokenomics: [`TOKENOMICS.md`](./TOKENOMICS.md)
- Phase 3 후속 minter 계획 (halving, known-output bonus): [`PHASE-3-PLAN.md`](./PHASE-3-PLAN.md)
- 인덱싱 / dashboard: [`INDEXING.md`](./INDEXING.md)
