#!/bin/sh
# 시험 한 층을 고른다. **기본은 가장 싼 층이다.**
#
#   ./Scripts/test.sh            L0        PCC 0 · 기기 모델 0 · 네트워크 0   매 커밋
#   ./Scripts/test.sh local      L0+L1     기기 모델만                        큰 변경
#   ./Scripts/test.sh pcc        L0..L2    PCC 1~2회 · 웹은 대역               하루 몇 번
#   ./Scripts/test.sh e2e        L0..L3    PCC + 살아 있는 웹                  릴리스 후보
#
# 뒤에 붙인 인자는 xcodebuild로 그대로 간다(`-only-testing:…`).
#
# **층은 클래스로 고른다.** 환경 변수로 고르는 길을 먼저 만들었고, 그 길은 서지
# 않았다(실측 2026-09-17): `xcodebuild test`는 호스트 환경도
# `TEST_RUNNER_<VAR>`도 이 패키지의 시험 프로세스에 전달하지 않는다. 전달되지 않는
# 스위치는 "끈 줄 알았는데 돌고 있었다"보다 나쁘다 — 그래서 선택을 명령줄에 둔다.
#
# 이 패키지는 iOS 전용이라 `swift test`가 서지 않는다 — 대상은 시뮬레이터다.
set -eu

# 층별 시험 클래스. 새 층 시험을 더하면 여기에 이름을 적는다.
L1_CLASSES="OnDeviceReductionTests"
L2_CLASSES=""
L3_CLASSES=""

mode="${1:-fast}"
[ $# -gt 0 ] && shift

case "$mode" in
  fast)  skip="$L1_CLASSES $L2_CLASSES $L3_CLASSES" ;;
  local) skip="$L2_CLASSES $L3_CLASSES" ;;
  pcc)   skip="$L3_CLASSES" ;;
  e2e)   skip="" ;;
  *) echo "usage: $0 [fast|local|pcc|e2e] [xcodebuild args...]" >&2; exit 2 ;;
esac

for class in $skip; do
  set -- "$@" "-skip-testing:AgentOrchestrationTests/$class"
done

: "${JS_TEST_DEVICE:=018D2516-4801-48C4-B7FF-38EBA8F5CBE2}"

exec xcodebuild test \
  -scheme ios-ai-core-Package \
  -destination "id=$JS_TEST_DEVICE" \
  "$@"
