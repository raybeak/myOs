# Gate 2 Starter: JavaCard (`SeedKeeper` + `SmartPGP`) & `sudo-rs` Auth

NXP JCOP3 SecID P60 (`Serial: 02627809`, `USB-C CCID`) 카드에 `SeedKeeper`와 `SmartPGP`(`nistp256`)를 공존시켜 **SSH, Git 커밋 서명, `sudo`/`sudo-i` 인증, Workspace `.env.gpg` 암복호화**를 100% Password Fallback과 함께 제공하는 가이드입니다.

---

## 1. Included Components (`~/myOs/`)

- `packagesV2.txt`: `pcscd`, `libccid`, `opensc`, `scdaemon`, `gnupg`, `pinentry-qt`, `libpam-ssh-agent-auth`.
- `dotfiles/gnupg/.gnupg/`: `gpg-agent.conf` (`enable-ssh-support`) + `scdaemon.conf` (`disable-ccid`, `pcscd` 단독 경유).
- `bootstrap.sh`: `gnupg`는 `stow --no-folding`으로 배포(개인키·Stub 유실 방지), `etc/sudoers.d/ssh-agent` (`0440`, `visudo -cf`), `etc/security/authorized_keys` (`0644`), `/etc/pam.d/sudo`·`sudo-i` `sufficient` 규칙 멱등 적용.
- `dotfiles/shell/.config/myos/env-helpers.sh`: `envlock`, `envview`, `envrun` (Dual-Recipient GPG 암복호화, `./.env.gpg` 우선 후 `~/workspace/.env.gpg` 자동 폴백, 디스크 평문 미생성).

---

## 2. Fresh Machine / Daily Commands

- **카드 인식 & SSH 활성화**: `gpg --import <pub.asc> && gpg --card-status && ssh-add -L`
- **Git 서명 활성화**: `git config --global user.signingkey 2020F34F7015C34F052A1A3E4BF8329DC5E9F845 && git config --global commit.gpgsign true`
- **Workspace `.env`**:
  - 암호화: `envlock` (`~/.config/myos/gpg-recipients` 참조)
  - 조회 / 실행: `envview` / `envrun <command>`
- **`gp` / `SeedKeeper` 툴 사용 전 락 해제**: `gpgconf --kill scdaemon` 실행 후 `java -jar ~/workspace/tools/gp.jar -l` 실행.
- **상세 아키텍처 & 작업 명세**: `~/workspace/javaCardAuth/{howItWorks.md,README.md,agentTaskSpecs.md}` 참고.
