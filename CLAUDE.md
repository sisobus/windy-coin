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
  - 본배포: Base mainnet (감사 후)
- **컨트랙트**: Solidity, OpenZeppelin (`AccessControl`, `ERC20Burnable`)
- **빌드/테스트**: Foundry
- **zkVM**: Risc Zero (RISC-V 기반, Rust guest)
- **windy-lang 인터프리터**: Rust 기반 (sisobus/windy) → guest program으로 vendoring

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
│   ├── guest/          # zkVM에서 실행될 windy-lang 인터프리터 (vendored)
│   ├── methods/        # build.rs로 guest를 ELF + image ID 상수로 변환 (호스트가 import)
│   └── host/           # proof 생성 호스트 프로그램
├── scripts/            # 배포 / 채굴 CLI
└── docs/
```

## 개발 로드맵
- [x] Foundry 환경 셋업
- [x] `Windy.sol` 작성 + 테스트 (cap, role-gated mint, burn)
- [ ] Base Sepolia에 토큰 배포
- [x] Risc Zero 환경 셋업 (hello-world prove + verify 통과)
- [ ] windy-lang 인터프리터를 zkVM guest로 포팅
- [ ] guest 프로그램: 인터프리터 실행 → 입력 commitment + 실행 결과를 public output
- [ ] `ZkExecutionMinter.sol` — Risc Zero on-chain verifier 통합, proof 받으면 mint
- [ ] 첫 채굴 성공 (testnet)
- [ ] 외부 감사
- [ ] Base mainnet 배포
- [ ] (Phase 2) Sonification NFT minter — windy-aria 결합

## 빌드 및 실행
TBD — Foundry 셋업 후 채움.

## 보안 / 신뢰 원칙
- Mainnet 배포 전 **외부 감사 필수**.
- Admin이 임의로 토큰을 mint/burn 할 수 없는 구조.
- 가능한 시점에 admin role을 `renounceRole`로 영구 폐기.
- ZK verifier는 Risc Zero 공식 verifier 컨트랙트만 사용 (자작 X).

## 참고
- 부모 오케스트레이션 repo: [sisobus-workspace](https://github.com/sisobus/sisobus-workspace)
- 인터프리터 출처: [sisobus/windy](https://github.com/sisobus/windy)
- Phase 2 결합 대상: [sisobus/windy-aria](https://github.com/sisobus/windy-aria)
