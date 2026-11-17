# Gate 3 Starter: `myosSweeper` (Standalone `/` Cybersec Sweeper)

외부 상용 AI 에이전트(`agy`, `claude`, `codex`, `cursor`)에 의존하지 않고 `/` 하위의 파일 무결성, SUID/SGID, 외부 리스닝 포트(`ss`), 인증 로그를 스캔해 이상 징후만 에스컬레이션하는 독립 보안 감사 모듈입니다.

---

## 1. Architecture & Components (`~/myOs/sweeper/`)

- `collectDelta.py`: `/` 기준 델타 수집기 + 결정론적 Rule Floor 평가(`addedSuidCount`, `tmpExecCount`, `newExternalPorts`, `dpkgVerifyMismatchCount`, `unownedSystemFilesCount`, `authFailCount`).
- `runJev.py`: 로컬 경량 추론기(`llama-cli`, `qwen2.5-1.5b` / `deepseek-r1-1.5b`) 실행 및 결정론적 판정.
- `escalateAndAlert.py`: 이상 탐지 시 Desktop(Tailscale 엔드포인트) 에스컬레이션 및 `swaync` 알림 출력(`[JEV+DESKTOP]` / `[JEV-LOCAL]`).
- `installSweeper.sh`: `/opt/myosSweeper`, `systemd` 타이머, `logrotate`, Waybar 모듈 배포 스크립트.
- `sweeper.conf`: 모델 경로/SHA-256, `SIGNING_KEY_ID`, `ALLOWED_EXTERNAL_PORTS`, `DESKTOP_ENDPOINT` 설정.

---

## 2. Quick Start

1. `sweeper/sweeper.conf`에서 `MODEL_SHA256`, `LLAMA_SHA256`, `ALLOWED_EXTERNAL_PORTS` 확인.
2. Desktop 에스컬레이션 사용 시 `/etc/myosSweeper/desktop.token` 및 `DESKTOP_ENDPOINT` 설정 (Git에 토큰 커밋 금지).
3. `baseline.json.asc` 서명에 SmartPGP 카드 키(`2020F34F7015C34F052A1A3E4BF8329DC5E9F845`) 또는 기존 `myosSweeper` 키 지정 후 `sudo ./sweeper/installSweeper.sh` 실행.
4. `evals/` 테스트로 Rule Floor 및 알림 파이프라인 검증.
