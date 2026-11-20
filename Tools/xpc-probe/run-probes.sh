#!/bin/bash
# XPC 거부 확인 (WO-7, 3-7). 저장소 루트에서: Tools/xpc-probe/run-probes.sh
#
# 양성 대조: 정품 앱 패널에 '연결됨'이 뜨는지 사람이 먼저 확인한 뒤, 패널 "종료"로 앱을 끄고 실행한다.
#   이 스크립트는 정품 앱을 띄우지 않는다. 대신 팀 인증서(Apple Development)로 서명한 프로브로 자동 양성
#   대조를 한 번 한다 — Debug 요구사항(팀 + identifier)만 맞추므로 Release 데몬에서는 거부되는 것이 맞다.
# 필요한 것: /Applications/Haetae.app 설치와 데몬 등록(7-1 P1). sudo는 쓰지 않는다.
# launchd 변경: 사용자 도메인(gui/$UID)에 가짜 서비스를 잠깐 올렸다가 지운다(중간에 죽어도 trap으로 지운다).
# 종료 코드: 0 = FAIL 없음, 1 = FAIL 있음, 2 = 사전 확인·빌드 실패
set -u
cd "$(dirname "$0")/../.." || exit 2

SERVICE=com.10000DOO.haetaed
AGENT=com.10000DOO.Haetae.agent
APP_ID=com.10000DOO.Haetae
APP=/Applications/Haetae.app
WORK=$(mktemp -d "${TMPDIR:-/tmp}/xpc-probe.XXXXXX") || exit 2
FAKE_LOADED=0
ROWS=()
EVIDENCE=()
FAILS=0
# 이 환경의 RTK 훅이 log show 출력을 비운다(8장).
LOG=(log)
command -v rtk >/dev/null && LOG=(rtk proxy log)

cleanup() {
    [ "$FAKE_LOADED" = 1 ] && launchctl bootout "gui/$UID/$SERVICE" 2>/dev/null
    pkill -f "$WORK/" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# limit 초 명령… — alarm은 exec 뒤에도 남아 시간이 지나면 SIGALRM으로 끝난다.
limit() { perl -e 'alarm shift; exec @ARGV or die "exec 실패: $!\n"' "$@"; }
daemon_gone() {
    for _ in $(seq 30); do pgrep -x haetaed >/dev/null || return 0; sleep 0.5; done
    return 1
}
reg_state() {
    for job in "system/$SERVICE" "gui/$UID/$AGENT"; do
        echo "$job: $(launchctl print "$job" 2>/dev/null | grep -E '^[[:space:]]*(path|program identifier) =' | tr -s ' \t' ' ')"
    done
}
row() {
    ROWS+=("| $1 | $2 | $3 | $4 |")
    [ "$4" = FAIL ] && FAILS=$((FAILS + 1))
}
evidence() { EVIDENCE+=("$1"$'\n'"${2:-  (로그 없음)}"); }
listener_log() {
    limit 30 "${LOG[@]}" show --info --style compact --start "$1" \
        --predicate "subsystem == \"$SERVICE\" AND category == \"listener\"" 2>&1 |
        grep -E '유효한 호출 없이|요구사항 없음|연결 0개' | sed 's/^/  /'
}

# probe 명령… — 데몬이 꺼진 상태에서 시작해 유휴 종료까지 기다린 뒤 그 사이 로그를 모은다.
# 데몬이 새로 떠야 "유효한 호출 없이 끊긴 연결"이 누적 1로 남는다(1, 2, 4, 8…번째만 남김).
probe() {
    R_OUT="" R_RC=2 R_LOGS="" R_INVALID=0 R_NOREQ=0
    if ! daemon_gone; then R_OUT="데몬이 15초 안에 끝나지 않음"; return 1; fi
    local t
    t=$(date '+%Y-%m-%d %H:%M:%S')
    R_OUT=$(limit 30 "$@" 2>&1)
    R_RC=$?
    daemon_gone
    R_LOGS=$(listener_log "$t")
    R_INVALID=$(grep -c '유효한 호출 없이' <<<"$R_LOGS")
    R_NOREQ=$(grep -c '요구사항 없음' <<<"$R_LOGS")
}
summary() { echo "$R_OUT (rc $R_RC) / 로그: 끊김 $R_INVALID, 요구사항없음 $R_NOREQ"; }
# 거부 판정: 응답을 받았으면 무조건 FAIL, 아니면 끊김 로그가 있고 "요구사항 없음"이 없어야 PASS.
reject_verdict() {
    if [ "$R_RC" = 1 ]; then echo FAIL
    elif [ "$R_INVALID" -ge 1 ] && [ "$R_NOREQ" = 0 ]; then echo PASS
    else echo FAIL; fi
}

# ── 사전 확인 ──
if ! launchctl print "system/$SERVICE" >/dev/null 2>&1; then
    echo "데몬이 등록돼 있지 않습니다 — 7-1 P1 '등록 출처' 절차로 설치·등록한 뒤 다시 실행하세요."; exit 2
fi
if pgrep -x Haetae >/dev/null; then
    echo "Haetae 앱이 실행 중입니다 — 패널에서 \"종료\"로 끈 뒤 다시 실행하세요(앱이 연결을 쥐고 있으면 데몬이 유휴 종료하지 않아 로그 판정이 어긋납니다)."; exit 2
fi
if launchctl print "gui/$UID/$SERVICE" >/dev/null 2>&1; then
    echo "사용자 도메인에 이미 $SERVICE가 있습니다 — 이전 실행이 남긴 것이면 launchctl bootout gui/$UID/$SERVICE 뒤 다시 실행하세요."; exit 2
fi
if ! daemon_gone; then echo "haetaed가 15초 안에 끝나지 않습니다 — 연결을 쥔 프로세스를 먼저 끄세요."; exit 2; fi
REG_BEFORE=$(reg_state)

# ── 빌드 ──
echo "빌드 중…"
if ! limit 300 swiftc -swift-version 6 -module-name xpcprobe -package-name HaetaeKit -o "$WORK/probe" \
    Tools/xpc-probe/main.swift HaetaeKit/Sources/HaetaeShared/*.swift; then
    echo "빌드 실패"; exit 2
fi
# ① codesign을 하지 않은 것 — swiftc 링커가 붙인 ad-hoc 서명만 있다(서명이 아예 없으면 arm64 커널이 실행을 막는다).
PROBE=$WORK/probe
cp "$PROBE" "$WORK/adhoc" && codesign -f -s - "$WORK/adhoc" 2>/dev/null
cp "$PROBE" "$WORK/fake-id" && codesign -f -s - -i "$APP_ID" "$WORK/fake-id" 2>/dev/null
TEAM_ID=$(plutil -extract HaetaeTeamID raw "$APP/Contents/Info.plist" 2>/dev/null)
TEAM=""
cp "$PROBE" "$WORK/team" &&
    limit 30 codesign -f -s "Apple Development" -i "$APP_ID" "$WORK/team" >/dev/null 2>&1 &&
    [ -n "$TEAM_ID" ] && codesign -dv "$WORK/team" 2>&1 | grep -qx "TeamIdentifier=$TEAM_ID" && TEAM=$WORK/team
# 설치된 데몬이 Release(Developer ID)면 팀 서명 프로브도 요구사항에 걸려야 한다(3-7). Authority 줄에는 실명이 있어 출력하지 않는다.
RELEASE=0
codesign -dvv "$APP/Contents/MacOS/haetaed" 2>&1 | grep -q '^Authority=Developer ID Application' && RELEASE=1

# ── ⓪ 자동 양성 대조(Release 데몬이면 거부 대조) ──
if [ -z "$TEAM" ]; then
    row "⓪ 팀 서명 프로브" "-" "팀 인증서로 서명하지 못함" "건너뜀"
elif [ "$RELEASE" = 1 ]; then
    probe "$TEAM"
    row "⓪ 팀 서명 프로브(Release 데몬)" "거부" "$(summary)" "$(reject_verdict)"
    evidence "⓪ 팀 서명 프로브(Release 데몬)" "$R_LOGS"
else
    probe "$TEAM"
    if [ "$R_RC" = 1 ] && [ "$R_NOREQ" = 0 ] && [ "$R_INVALID" = 0 ]; then V=PASS; else V=FAIL; fi
    row "⓪ 양성 대조(팀 서명 프로브, Debug 데몬)" "응답 받음" "$(summary)" "$V"
    evidence "⓪ 양성 대조(팀 서명 프로브, Debug 데몬)" "$R_LOGS"
fi

# ── ①~③ 서명이 맞지 않는 클라이언트 ──
for case in "① 서명 안 함(링커 ad-hoc만)|$PROBE" "② ad-hoc 서명|$WORK/adhoc" "③ ad-hoc + identifier $APP_ID 위장|$WORK/fake-id"; do
    NAME=${case%%|*}
    probe "${case#*|}"
    row "$NAME" "거부" "$(summary)" "$(reject_verdict)"
    evidence "$NAME" "$R_LOGS"
done

# ── ④ exec-swap: collect를 보낸 직후 다른 실행 파일(가능하면 요구사항을 통과하는 팀 서명본)로 바뀐다 ──
# 옛 연결은 exec와 함께 메모리째 사라지므로 "같은 연결로 다시 호출"은 할 수 없다. 대신 exec 전에 보낸 메시지를
# 데몬이 거부하는지(보낸 쪽이 지금은 요구사항을 통과하는 이미지여도), mach 포트 권한이 exec를 넘는지 본다.
NAME="④ exec-swap(→ $([ -n "$TEAM" ] && echo 팀 서명본 || echo ad-hoc))"
probe "$PROBE" --exec-swap "${TEAM:-$WORK/adhoc}"
# 새 이미지의 새 연결 결과: Debug 데몬에 팀 서명본이면 성공(양성 대조), 아니면 거부여야 한다. 끊김 로그는 exec 전 메시지 몫이다.
# 직전 기동 약 10초 안에는 launchd가 데몬을 늦게 띄워서(실측, throttle로 보임) 직전 시험 뒤에는 데몬이 exec보다 늦게 떠 메시지를 exec 뒤에 검사한다.
if [ -z "$TEAM" ] || [ "$RELEASE" = 1 ]; then V=$(reject_verdict)
elif [ "$R_RC" = 1 ] && [ "$R_INVALID" -ge 1 ] && [ "$R_NOREQ" = 0 ]; then V=PASS
else V=FAIL; fi
SWAP_AT=$(sed -nE 's/.*exec뒤시작=([0-9:.]+).*/\1/p' <<<"$R_OUT")
REJECT_AT=$(grep -m1 '유효한 호출 없이' <<<"$R_LOGS" | awk '{print substr($2, 1, 12)}')
ORDER="확실하지 않음"
if [ -n "$SWAP_AT" ] && [ -n "$REJECT_AT" ]; then
    if [[ "$REJECT_AT" > "$SWAP_AT" ]]; then ORDER="끊김($REJECT_AT)이 exec($SWAP_AT) 뒤"; else ORDER="끊김($REJECT_AT)이 exec($SWAP_AT) 전"; fi
fi
row "$NAME" "exec 전 메시지 거부" "$(summary) / $ORDER" "$V"
evidence "$NAME" "$R_LOGS"

# ── ⑤ 메시지 없이 연결만 붙잡기 ──
NAME="⑤ 메시지 없이 연결만 붙잡기(20초)"
if daemon_gone; then
    "$PROBE" --hold 20 >"$WORK/hold.out" 2>&1 &
    HOLD=$!
    LAUNCHED=아니오
    for _ in $(seq 10); do pgrep -x haetaed >/dev/null && LAUNCHED=예; sleep 0.5; done
    T=$(date '+%Y-%m-%d %H:%M:%S')
    OUT=$(limit 30 "$PROBE" 2>&1)   # 붙잡은 채로 다른 프로브가 데몬을 띄운다
    START=$SECONDS
    GONE=아니오
    while kill -0 "$HOLD" 2>/dev/null; do
        pgrep -x haetaed >/dev/null || { GONE=예; break; }
        sleep 0.5
    done
    WAITED=$((SECONDS - START))
    wait "$HOLD"
    HELD=$(cat "$WORK/hold.out")
    daemon_gone
    LOGS=$(listener_log "$T")
    RESULT="붙잡기만으로 데몬 기동: $LAUNCHED / 다른 프로브($OUT) 뒤 붙잡은 채 유휴 종료: $GONE(${WAITED}초) / $HELD"
    if [ "$LAUNCHED" = 아니오 ] && [ "$GONE" = 예 ]; then V=PASS; else V=발견; fi
    row "$NAME" "데몬이 띄워지지도 붙잡히지도 않음" "$RESULT" "$V"
    evidence "$NAME" "$LOGS"
else
    row "$NAME" "데몬이 띄워지지도 붙잡히지도 않음" "데몬이 15초 안에 끝나지 않음" FAIL
fi

# ── ⑥ 사용자 도메인 가짜 서비스 ──
NAME="⑥ 사용자 도메인에 같은 이름 가짜 서비스"
MARKER=$WORK/fake-launched
cat >"$WORK/fake.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$SERVICE</string>
<key>ProgramArguments</key><array>
<string>/bin/sh</string><string>-c</string><string>echo launched &gt;&gt; "\$0"; sleep 3</string><string>$MARKER</string>
</array>
<key>MachServices</key><dict><key>$SERVICE</key><true/></dict>
</dict></plist>
EOF
fake_up() { launchctl bootstrap "gui/$UID" "$WORK/fake.plist" 2>"$WORK/bootstrap.err" && FAKE_LOADED=1; }
# 메시지가 남은 가짜는 launchd가 다시 띄울 수 있어, 시험마다 지우고 새로 올린다.
fake_down() { launchctl bootout "gui/$UID/$SERVICE" 2>/dev/null; FAKE_LOADED=0; }
if fake_up; then
    # 대조: .privileged 없이 찾으면 가짜로 가야 이 시험이 의미가 있다.
    CONTROL=$(limit 15 "$PROBE" --no-privileged --timeout 5 2>&1)
    sleep 1
    REACHED=아니오
    [ -e "$MARKER" ] && REACHED=예
    fake_down
    rm -f "$MARKER"
    if fake_up; then
        probe "$PROBE"
        sleep 1
        FAKE_HIT=아니오
        [ -e "$MARKER" ] && FAKE_HIT=예
        fake_down
        V=$(reject_verdict)
        [ "$FAKE_HIT" = 예 ] && V=FAIL
        row "$NAME" ".privileged는 진짜 데몬으로" "대조(.privileged 없음 → 가짜 기동: $REACHED, $CONTROL) / .privileged → 가짜 기동: $FAKE_HIT, $(summary)" "$V"
        evidence "$NAME" "$R_LOGS"
    else
        row "$NAME" ".privileged는 진짜 데몬으로" "다시 bootstrap 실패: $(cat "$WORK/bootstrap.err")" FAIL
    fi
else
    row "$NAME" ".privileged는 진짜 데몬으로" "bootstrap 실패: $(cat "$WORK/bootstrap.err")" FAIL
fi

# ── 정리 확인 ──
pkill -f "$WORK/" 2>/dev/null
LEFT=$(launchctl print "gui/$UID/$SERVICE" >/dev/null 2>&1 && echo "가짜 서비스 남음" || echo "가짜 서비스 없음")
REG_AFTER=$(reg_state)
if [ "$REG_BEFORE" = "$REG_AFTER" ] && [ "$LEFT" = "가짜 서비스 없음" ]; then V=PASS; else V=FAIL; fi
row "⑦ 정리" "등록 상태 그대로, 가짜 없음" "$LEFT / 데몬·agent 등록 $([ "$REG_BEFORE" = "$REG_AFTER" ] && echo 같음 || echo 바뀜)" "$V"

echo
echo "XPC 거부 확인 (WO-7) — $(date '+%Y-%m-%d %H:%M')"
echo "양성 대조(사람): 정품 앱 패널에 '연결됨'이 뜨는지 먼저 확인했어야 한다 — 이 스크립트는 정품 앱을 띄우지 않는다."
echo
echo "| 시험 | 기대 | 결과 | 판정 |"
echo "|---|---|---|---|"
printf '%s\n' "${ROWS[@]}"
echo
echo "근거 로그 (subsystem $SERVICE, category listener):"
printf '%s\n' "${EVIDENCE[@]}"
[ "$FAILS" = 0 ]
