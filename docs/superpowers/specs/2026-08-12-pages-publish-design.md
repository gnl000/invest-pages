# invest-pages 자동 게시 설계

- 날짜: 2026-08-12
- 저장소: `invest-pages` (`invest\pages\`), 브랜치 `main`, SSH remote (`git@github.com:gnl000/invest-pages.git`)
- 목적: `event-news`, `kpi-setting`, `value-tracking-agent` 3개 독립 프로젝트가 각자 실행될 때 산출물을 `invest\pages\<프로젝트명>\`으로 복사하고, 같은 워킹 디렉터리(`pages`)에서 pull/add/commit/push까지 자동으로 수행해 GitHub Pages가 항상 최신 상태를 반영하게 한다.

## 배경 / 기존 상태

- `event-news`, `kpi-setting`, `value-tracking-agent`, `pages` 는 각각 별도 git 저장소이며 `invest` 루트는 git 저장소가 아니다.
- 세 프로젝트 중 어느 것도 지금까지 "실행 후 자기 저장소에 자동 commit/push" 로직이 없었다. 이번이 최초의 git 자동화다.
- `pages` 저장소는 최초 상태(커밋 0개)였고, 이번 설계 진행 중 최초 부트스트랩 커밋(`af134cb`, 2026-08-12)으로 랜딩 페이지 + event-news daily/weekly + value-tracking-agent 최신 분기 대시보드 + kpi-setting 준비중 페이지를 push 완료했다.
- SSH 인증은 계정 전체 키(`id_ed25519`, 패스프레이즈 제거됨)로 등록되어 있고 정상 동작 확인됨.

## 프로젝트별 게시 범위

| 프로젝트 | 게시 대상 | 파일 정책 | 트리거 지점 |
|---|---|---|---|
| event-news (daily) | `pages/event-news/daily.html` | 고정 파일명, 매번 덮어쓰기 | `run_agent.bat` — `claude -p` 성공(RC=0) 직후 |
| event-news (weekly) | `pages/event-news/weekly.html` | 고정 파일명, 매번 덮어쓰기 | `run_weekly_now.bat`, `run_weekly_reuse.bat` — 성공(RC=0) 직후 |
| value-tracking-agent | `pages/value-tracking-agent/<원본파일명>.html` + `pages/value-tracking-agent/latest.html` | 원본 파일명 그대로 누적 보관(분기 단위라 저장소 부담 적음) + `latest.html`은 매번 최신본으로 덮어쓰기 | `scripts/build_dashboard.py` 실행 완료 시마다 자동 (수동 재실행/실험적 변형 포함, 사용자가 명시적으로 선택함) |
| kpi-setting | — | 보류. `pages/kpi-setting/index.html`은 "준비 중" placeholder만 존재 | 없음 (이번 범위 제외) |

`value-tracking-agent`의 분기 대시보드는 systemd 타이머(`quarterly-trigger`/`quarterly-notify`)만 있고 대응하는 `.service`가 없어 실제로는 사람이 Windows에서 수동으로 `build_dashboard.py`를 실행하는 구조임을 확인했다. 매 실행마다 자동 게시하기로 결정했으므로, 실험적 재실행(`-rg1`, `_regraded_` 등)도 그대로 공개 사이트에 올라간다는 점을 사용자가 인지하고 동의함.

## 공용 게시 스크립트: `pages/tools/publish.ps1`

프로젝트마다 git 로직을 중복 구현하지 않도록 단일 PowerShell 스크립트로 통일한다. 호출부(각 프로젝트의 `run_agent.bat`, `run_weekly_now.bat`, `build_dashboard.py`)는 "내 파일 경로 → publish.ps1 호출" 한 줄만 추가한다.

파라미터:
- `-Project` : 대상 하위폴더명 (`event-news`, `value-tracking-agent`)
- `-Abbrev` : 커밋 메시지용 약어 (`EN`, `VT`)
- `-Copy` : `@{ "소스절대경로" = "pages/<Project>/ 기준 상대 목적 경로" }` 형태의 매핑 (여러 쌍 가능)

동작 순서:
1. `pages/.publish.lock` 디렉터리를 `New-Item -ItemType Directory`로 원자적 생성 시도 (mkdir 락). 이미 존재하면 5초 간격으로 재시도하며, lock 내부 타임스탬프 파일이 5분 이상 오래됐으면 stale로 간주해 강제 회수. 3분 넘게 획득 못 하면 에러 로그 남기고 중단(exit 비정상 종료, 산출물 자체 실행은 실패시키지 않도록 이 실패는 별도 로그로만 남김).
2. lock 획득 후: `git pull --rebase origin main` → `-Copy`에 명시된 파일들을 목적 경로로 복사 → **자기 프로젝트 하위폴더만** `git add`(`git add -A` 금지, 다른 프로젝트가 동시에 복사해둔 미커밋 파일을 실수로 같이 add하는 것을 방지) → 스테이징된 변경이 없으면 커밋/푸시 스킵 → 변경 있으면 `git commit -m "auto update <Abbrev> <yyyy-MM-dd HH:mm>"` → `git push origin main`.
3. push 실패 시 (원격에 새 커밋이 생겨 non-fast-forward 등) `git pull --rebase` 후 재시도, 최대 3회.
4. `finally` 블록에서 lock 디렉터리 항상 해제.
5. 모든 단계는 `pages/tools/publish.log`에 타임스탬프와 함께 append 로그.

이 lock은 세 스크립트가 동일한 `pages` 워킹 디렉터리에서 `git add/commit`을 동시에 실행할 때 발생할 수 있는 `.git/index.lock` 충돌 및 interleaved pull/push 경쟁을 막기 위한 것이다. 각 프로젝트가 서로 다른 하위폴더만 건드리므로 파일 내용 충돌은 없으나, git 명령 자체의 동시 실행은 방어가 필요하다는 것이 최초 요청의 전제였다.

## 인증

- `pages` remote는 SSH(`git@github.com:gnl000/invest-pages.git`)로 통일. 계정 전체 SSH 키를 사용하며 무인 실행(Windows Task Scheduler, "로그인 없이 실행")에서도 프롬프트 없이 동작하도록 **패스프레이즈를 제거**했다 (사용자 직접 수행, 2026-08-12).
- 이 키는 event-news/kpi-tracking/value-tracking 3개 저장소에서도 동일하게 사용 중 — 패스프레이즈 제거로 이 4개 저장소 전체의 키 보안 수준이 낮아졌음을 사용자가 인지하고 동의함 (대안이었던 "자동화 전용 별도 키" 대신 기존 키 재사용을 선택).

## GitHub Pages

- Source: `main` 브랜치, `/` (root)
- URL: `https://gnl000.github.io/invest-pages/`

## 제외 범위 / 후속 과제

- kpi-setting 연동은 온보딩 진행 후 별도로 다룬다.
- event-news/value-tracking-agent 외 프로젝트가 추가되면 동일한 `publish.ps1`을 재사용한다.
