# windy-coin

## 개요
WNDY는 windy-lang 프로그램의 정직한 실행을 ZK 증명으로 검증해야만 발행되는 ERC-20 토큰이다.
Bitcoin의 무차별 해시 기반 PoW를 *의미 있는 계산(esolang 실행)*으로 대체하는 "Useful PoW" 실험.

- **Phase 1**: ERC-20 + ZkExecutionMinter (Proof-of-Windy)
- **Phase 2 (예정)**: Sonification NFT + bonding curve — windy-aria 결합

## 토큰 스펙 (확정 / 변경 불가)
| 항목 | 값 |
|------|----|
| 이름 | Windy |
| 심볼 | WNDY |
| Decimals | 18 |
| Hard cap | 21,000,000 WNDY (Bitcoin 오마주) |
| Pre-mine | 0% (순수 fair launch) |
| 발행 | MINTER_ROLE 보유 컨트랙트만 가능 |

## 기술 스택
- **체인**: Base
  - 개발/테스트: Base Sepolia
  - 본배포: Base mainnet — **live since 2026-05-11** (감사 없이 자체 baseline만으로 진입, 아래 "보안 / 신뢰 원칙" 참조)
- **컨트랙트**: Solidity, OpenZeppelin (`AccessControl`, `ERC20Burnable`)
- **빌드/테스트**: Foundry
- **zkVM**: Risc Zero (RISC-V 기반, Rust guest)
- **windy-lang 인터프리터**: Rust 기반 (sisobus/windy-lang) → guest program으로 vendoring

## 아키텍처 원칙
1. **토큰 컨트랙트는 한 번 배포 후 영구 불변**
   새 mint 메커니즘은 별도 Minter 컨트랙트로 추가, `MINTER_ROLE` 부여만으로 통합.
2. **Hard cap은 코드상 절대 변경 불가** — admin도 못 바꿈. 이게 신뢰의 핵심.
3. **Burn 가능** — Phase 2 디플레이션 압력 대비.
4. **Admin 권한 점진적 분권화** — 초기 EOA → 멀티시그 → 최종적으로 renounce 또는 DAO.

## 프로젝트 구조 (계획)
```
windy-coin/
├── contracts/          # Foundry 프로젝트
│   ├── src/
│   │   ├── Windy.sol             # ERC-20 (불변)
│   │   └── ZkExecutionMinter.sol # Phase 1 minter (Risc Zero verifier 통합)
│   ├── test/
│   └── script/
├── circuit/            # Risc Zero zkVM workspace
│   ├── core/           # WindyInput/WindyJournal 공유 타입 (no_std, guest+host 양쪽 사용)
│   ├── guest/          # zkVM에서 실행될 windy-lang 인터프리터 (windy-lang crates.io dep)
│   ├── methods/        # build.rs로 guest를 ELF + image ID 상수로 변환 (호스트가 import)
│   ├── host/           # CLI: 프로그램/seed/max_steps를 ExecutorEnv로 주입, proof 생성/검증
│   └── programs/       # 샘플 windy-lang 프로그램 (현재 hello.wnd)
├── scripts/            # 배포 / 채굴 CLI
└── docs/
```

## 개발 로드맵
- [x] Foundry 환경 셋업
- [x] `Windy.sol` 작성 + 테스트 (cap, role-gated mint, burn)
- [x] Base Sepolia에 토큰 배포 (`0x17436284Cdc6b86F9281BBdc77161453ef1C9728`, source-verified)
- [x] Risc Zero 환경 셋업 (hello-world prove + verify 통과)
- [x] windy-lang 인터프리터를 zkVM guest로 포팅 (Phase 1.3a: hardcoded `hello.wnd` 실행, journal에 program/output hash + exit code + steps 커밋)
- [x] guest 프로그램: 인터프리터 실행 → 입력 commitment + 실행 결과를 public output (Phase 1.3b: 호스트가 `WindyInput {program, seed, max_steps, stdin}`을 ExecutorEnv로 주입; journal의 program_hash가 입력 커밋, output_hash + exit_code + steps가 실행 결과 public output)
- [x] journal에 recipient/nonce 추가 + ABI encoding (Phase 1.4a: alloy `sol!` 매크로로 `WindyJournalSol`, `commit_slice`로 192-byte ABI payload — Solidity가 `abi.decode`로 직접 파싱)
- [x] 다양한 windy 프로그램으로 통합 검증 (Phase 1.6: `circuit/programs/`에 6개 프로그램 — hello, hello_winds, hi_windy, sum_winds, fib, factorial. 각각 24~912 steps, 모두 zkVM에서 Ok exit. ABI/serde round-trip 유닛 테스트 4개 추가. journal hash 표는 `programs/README.md`)
- [x] `ZkExecutionMinter.sol` — Risc Zero on-chain verifier 통합, proof 받으면 mint (Phase 1.4b: free-mint 정책 — valid proof + nonce 미사용 → recipient에 고정 REWARD mint. risc0-ethereum v3.0.1 `IRiscZeroVerifier`, RiscZeroMockVerifier 기반 Foundry tests 7개 통과: happy path, distinct nonces, replay rejection, bad seal, tampered journal, missing MINTER_ROLE, reward > MAX_SUPPLY)
- [x] 첫 채굴 성공 (testnet) — `puzzle_hard.wnd` proof로 Silver tier 1.0 WNDY mint. tx [`0xe4d64259...0034d2`](https://sepolia.basescan.org/tx/0xe4d6425907f22e32571690a542f879c4ef4608d00cee14b56eaac0fe9a0034d2), score 34.30, gas 376k. Bonsai/Boundless 안 살아도 로컬 risc0 + Docker로 Groth16 wrap (multi-arch image v2025-04-03.1) 가능했음 — host에 selector prefix만 추가하면 됐음 (encode_seal 동등 로직).
- [x] ~~외부 감사~~ — 2026-05-09 결정으로 스킵 (아래 "보안 / 신뢰 원칙" 섹션 참조)
- [x] Base mainnet 배포 — 2026-05-11. `DeployMainnet.s.sol` 단일 atomic broadcast로 Windy + V2 minter 동시 배포 + `MINTER_ROLE` grant + admin/pauser → Safe(`0x1143569f...75D7`) 이관 + deployer EOA의 모든 권한 renounce 한 번에 처리. 컨트랙트 주소: Windy [`0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca`](https://basescan.org/address/0x8c64a92e3a12f5ca4050b5fb90804bd24cd653ca#code), V2 minter [`0xc566ab14616662ae92095a72a8cc23bf62b6ff02`](https://basescan.org/address/0xc566ab14616662ae92095a72a8cc23bf62b6ff02#code). 둘 다 source-verified. 9-tx broadcast 기록은 [`contracts/broadcast/DeployMainnet.s.sol/8453/run-latest.json`](./contracts/broadcast/DeployMainnet.s.sol/8453/run-latest.json). Gas 0.0101 gwei, 총 ~3M gas, 비용 약 0.00003 ETH.
- [x] 첫 채굴 성공 (mainnet) — 2026-05-11. `puzzle_hard.wnd` proof로 Silver tier 1.0 WNDY mint (recipient = deployer EOA `0xCE13...5167`). tx [`0x97310d28...4c54c`](https://basescan.org/tx/0x97310d285fd88d1393c9ac858c71ca9a10dcb369601e08a6bdad415e734ac54c), block 45894604. journal 메트릭: steps 18, visitedCells 15, scoreX1000 34300, tier 2 (Silver), programHash `0x9b1031...931c`, outputHash `0xa3a2a5...54ef`. 직후 같은 proof 재전송 시도가 `ProgramAlreadyConsumed(0x9b1031...931c)` 로 revert 되며 first-claim dedup 정책이 mainnet에서 동작함도 함께 검증됨. mainnet 채굴 가이드: [`docs/MINING-GUIDE.md`](./docs/MINING-GUIDE.md).
- [x] 첫 Gold tier 채굴 (mainnet) — 2026-05-13. `fib_gold.wnd` proof로 Gold tier 10.0 WNDY mint. fib.wnd의 카운터 초기화 `55+` (=10) → `99*` (=81) 한 글자 변경으로 81 iter, writes 246 / branches 81 / visited 100 / diversity {p, g, |} → scoreX1000 87780 (= 87.780). tx [`0x336fcf86...88783`](https://basescan.org/tx/0x336fcf86373ab02f25b914058f3e911ef62b27d034bbadf76661b938b6788783), block 45921336, programHash `0x838716...0afce`. mainnet totalSupply: 1.0 → 11.0 WNDY. None / Bronze / Silver / Gold tier 4단 dispatch가 mainnet에서 정상 작동함을 확인.
- [x] Phase 2 mining 정책 구현 — design spec은 [`docs/PHASE-2-MINING.md`](./docs/PHASE-2-MINING.md). free-mint → tier-based (None / Bronze 0.1 / Silver 1 / Gold 10 WNDY) 마이그레이션 완료. V2 minter Sepolia 배포 (`0x03bd354738f5776c5c00a30024192c61c3f53c97`, source-verified), V1 minter `MINTER_ROLE` 회수 + `pause()` 처리. Session A (windy-lang v2.2.1 + visited_cells journal v2), Session B (`ZkExecutionMinterV2.sol` + 25 tests, 100% coverage, Slither 0), Session C (Sepolia 배포 + V1 retirement) 다 완료.
- [ ] (Phase 3) Sonification NFT minter — windy-aria 결합

## 빌드 및 실행
TBD — Foundry 셋업 후 채움.

## 보안 / 신뢰 원칙
- ~~Mainnet 배포 전 **외부 감사 필수**~~ → 2026-05-09 결정 변경: windy-coin은 실험적 / 취미 성격의 useful-PoW 토큰이고 즉각적 재정 위험 노출이 제한적. 외부 유료 감사는 비용 대비 효율이 떨어진다고 판단해 **자체 검증만으로 mainnet 진입**. 자체 baseline은 충분히 강함 (아래 항목들). 향후 실제 가치/유동성이 모이면 그 시점에 재감사.
- Admin이 임의로 토큰을 mint/burn 할 수 없는 구조.
- 가능한 시점에 admin role을 `renounceRole`로 영구 폐기.
- ZK verifier는 Risc Zero 공식 verifier 컨트랙트만 사용 (자작 X).
- 자체 audit baseline:
  - 61 Foundry tests 통과 (15 Windy + 11 V1 + 35 V2)
  - 7 fuzz tests × 256 runs = 1,792 randomized executions
  - `forge coverage` 100% (라인/브랜치/함수) on production contracts
  - **Slither** (정적 분석, 99 detectors) — 0 findings (`naming-convention` + `cyclomatic-complexity` 정당하게 비활성화)
  - **Mythril** (ConsenSys symbolic execution) — `Windy.sol` + `ZkExecutionMinterV2.sol` 모두 `No issues were detected`
  - `Pausable` + `PAUSER_ROLE` (mint 비상 동결 가능)
  - `consumedNonce` + `consumedProgram` dedup
  - 21M hard cap immutable, pre-mine 0
  - Sepolia 첫 채굴 검증 통과 (1.0 WNDY at Silver tier)
  - `Cargo.lock` committed (reproducible IMAGE_ID)
  - Multisig admin migration script 준비 (`MigrateAdmin.s.sol`)
  - Mainnet atomic deploy + 즉시 admin renounce script (`DeployMainnet.s.sol`) — **실행 완료 2026-05-11**, deployer EOA는 broadcast 종료 시점에 권한 0

## 참고
- 부모 오케스트레이션 repo: [sisobus-workspace](https://github.com/sisobus/sisobus-workspace)
- 인터프리터 출처: [sisobus/windy-lang](https://github.com/sisobus/windy-lang)
- Phase 2 결합 대상: [sisobus/windy-aria](https://github.com/sisobus/windy-aria)
