#!/usr/bin/env bash
# gpu_full_diagnose.sh
# AMD + Wayland용 종합 그래픽 진단 스크립트 (개선버전)
# 실행: sudo ./gpu_full_diagnose.sh
# 결과: ~/gpu_full_diagnose 폴더에 로그와 요약 파일 생성

set -euo pipefail

OUTDIR=~/gpu_full_diagnose
LOG="${OUTDIR}/gpu_diagnose.log"
SUMMARY="${OUTDIR}/gpu_diagnose_summary.txt"
REPORT="${OUTDIR}/gpu_diagnose_report.html"
mkdir -p "$OUTDIR"
: > "$LOG"
: > "$SUMMARY"

timestamp() { date +'%Y-%m-%d %H:%M:%S'; }

echo "=== GPU Full Diagnose (Enhanced Version) ===" >> "$LOG"
echo "생성 시간: $(timestamp)" >> "$LOG"
echo "사용자: $(whoami)" >> "$LOG"
echo "호스트: $(hostname)" >> "$LOG"
echo "" >> "$LOG"

note() { echo "[$(timestamp)] $*" >> "$LOG"; }
warn() { echo "WARNING: $*"; echo "WARNING: $*" >> "$LOG"; }
crit() { echo "CRITICAL: $*"; echo "CRITICAL: $*" >> "$LOG"; }
info() { echo "INFO: $*"; echo "INFO: $*" >> "$LOG"; }

###########################
# 헬퍼: 명령 존재 확인
###########################
check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo " * '$1' 명령이 없습니다. (권장: pacman -S $2)" >> "$LOG"
    return 1
  fi
  return 0
}

###########################
# 0) 환경 변수 및 현재 세션 정보
###########################
note "### 0) 환경 변수 및 세션 정보"
echo "WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-not set}" >> "$LOG"
echo "XDG_SESSION_TYPE: ${XDG_SESSION_TYPE:-not set}" >> "$LOG"
echo "XDG_CURRENT_DESKTOP: ${XDG_CURRENT_DESKTOP:-not set}" >> "$LOG"
echo "DISPLAY: ${DISPLAY:-not set}" >> "$LOG"
echo "DESKTOP_SESSION: ${DESKTOP_SESSION:-not set}" >> "$LOG"
echo "현재 실행중인 디스플레이 서버:" >> "$LOG"
pgrep -af 'wayland|Xwayland|Xorg' >> "$LOG" || echo "(디스플레이 서버 프로세스 없음)" >> "$LOG"
echo "" >> "$LOG"

###########################
# 1) 기본 시스템 / GPU 정보
###########################
note "### 1) 시스템 및 GPU 정보 수집"
echo "--- lspci -k (VGA/3D/Display)" >> "$LOG"
lspci -nnk | grep -EA4 'VGA|3D|Display' >> "$LOG" 2>&1 || echo "(lspci 실패 또는 출력 없음)" >> "$LOG"
echo "" >> "$LOG"

note "uname 및 커널"
uname -a >> "$LOG"
echo "부트 커맨드라인:" >> "$LOG"
cat /proc/cmdline >> "$LOG" 2>/dev/null || echo "(커맨드라인 읽기 실패)" >> "$LOG"
echo "" >> "$LOG"

note "lsmod (amdgpu / radeon / drm 로드 여부)"
lsmod | egrep 'amdgpu|radeon|drm' >> "$LOG" || echo "(관련 모듈 없음)" >> "$LOG"
echo "" >> "$LOG"

note "modinfo amdgpu (가능하면)"
if check_cmd modinfo kmod; then
  modinfo amdgpu >> "$LOG" 2>&1 || echo "(modinfo amdgpu 실패)" >> "$LOG"
else
  echo "modinfo 명령 없음" >> "$LOG"
fi
echo "" >> "$LOG"

###########################
# 1.5) DRM 카드 정보 상세
###########################
note "### 1.5) DRM 카드 정보 상세"
for card in /sys/class/drm/card*; do
  if [ -d "$card" ]; then
    cardname=$(basename "$card")
    echo "=== $cardname ===" >> "$LOG"
    [ -r "$card/device/vendor" ] && echo "vendor: $(cat "$card/device/vendor" 2>/dev/null)" >> "$LOG"
    [ -r "$card/device/device" ] && echo "device: $(cat "$card/device/device" 2>/dev/null)" >> "$LOG"
    [ -r "$card/device/subsystem_vendor" ] && echo "subsystem_vendor: $(cat "$card/device/subsystem_vendor" 2>/dev/null)" >> "$LOG"
    [ -r "$card/device/subsystem_device" ] && echo "subsystem_device: $(cat "$card/device/subsystem_device" 2>/dev/null)" >> "$LOG"
    [ -r "$card/device/driver/module/version" ] && echo "driver version: $(cat "$card/device/driver/module/version" 2>/dev/null)" >> "$LOG"
    echo "" >> "$LOG"
  fi
done

###########################
# 2) 설치된 패키지 체크
###########################
note "### 2) 그래픽 관련 패키지 설치 상태"
PKGS=(xf86-video-amdgpu mesa vulkan-radeon libva libglvnd vulkan-icd-loader radeontop 
      mesa-demos vulkan-tools lib32-mesa lib32-vulkan-radeon xorg-server-xwayland
      pipewire pipewire-alsa pipewire-pulse wireplumber)
for p in "${PKGS[@]}"; do
  if pacman -Qi "$p" &>/dev/null; then
    pacman -Qi "$p" | awk '/Name|Version|Installed Size/ {print}' >> "$LOG"
  else
    echo "$p : NOT INSTALLED" >> "$LOG"
  fi
done
echo "" >> "$LOG"

###########################
# 3) journalctl / dmesg - GPU/DRM/Wayland/Xorg 관련 에러
###########################
note "### 3) journalctl & dmesg 검사 (GPU/DRM/Wayland/XWayland 등)"
# 전체 부팅 로그에서 GPU/DRM/Wayland/Xorg 관련 키워드 필터
journalctl -b --no-pager | egrep -i 'amdgpu|radeon|drm|gpu|hang|fail|error|segfault|XWayland|Xorg|gnome-shell|kwin_wayland|sway|weston|wayland|libinput|pipewire' > "${OUTDIR}/journal_keywords.log" || true
echo "Saved journal keyword matches to ${OUTDIR}/journal_keywords.log" >> "$LOG"

# 최근 1시간 로그도 별도 저장
journalctl --since "1 hour ago" --no-pager > "${OUTDIR}/journal_recent.log" || true
echo "Saved recent 1h journal to ${OUTDIR}/journal_recent.log" >> "$LOG"

note "dmesg (커널 로그)에서 GPU/firmware/hang/oom 검사"
dmesg > "${OUTDIR}/dmesg_full.log" 2>/dev/null || true
dmesg | egrep -i 'amdgpu|radeon|firmware|GPU|hang|fault|oom|error|panic|call trace' > "${OUTDIR}/dmesg_keywords.log" || true
echo "Saved dmesg matches to ${OUTDIR}/dmesg_keywords.log" >> "$LOG"
echo "" >> "$LOG"

###########################
# 4) Xorg / XWayland 검사
###########################
note "### 4) Xorg / XWayland 검사"
if [ -f /var/log/Xorg.0.log ]; then
  grep -iE '(EE)|(WW)' /var/log/Xorg.0.log > "${OUTDIR}/Xorg_EE_WW.log" || true
  echo "Saved /var/log/Xorg.0.log EE/WW to ${OUTDIR}/Xorg_EE_WW.log" >> "$LOG"
fi

# 사용자별 Xorg 로그도 확인
for xlog in ~/.local/share/xorg/Xorg.*.log; do
  if [ -f "$xlog" ]; then
    grep -iE '(EE)|(WW)' "$xlog" > "${OUTDIR}/user_Xorg_EE_WW.log" || true
    echo "Saved user Xorg log EE/WW to ${OUTDIR}/user_Xorg_EE_WW.log" >> "$LOG"
    break
  fi
done
echo "" >> "$LOG"

###########################
# 5) Wayland/Compositor 검사
###########################
note "### 5) Wayland / Compositor (gnome-shell, kwin_wayland, sway, weston 등) 검사"
# 프로세스 확인
ps aux | egrep 'gnome-shell|kwin_wayland|sway|weston|wayland|pipewire|wireplumber' | head -n 100 > "${OUTDIR}/compositor_procs.log" || true
echo "Compositor processes -> ${OUTDIR}/compositor_procs.log" >> "$LOG"

# journal에서 구체 검색
journalctl -b --no-pager | egrep -i 'gnome-shell|kwin_wayland|kwin|sway|weston|xwayland|XWayland|pipewire|wireplumber' > "${OUTDIR}/compositor_journal.log" || true
echo "Compositor journal matches -> ${OUTDIR}/compositor_journal.log" >> "$LOG"

# Wayland 소켓 확인
echo "Wayland 소켓 상태:" >> "$LOG"
ls -la /run/user/*/wayland-* 2>/dev/null >> "$LOG" || echo "(Wayland 소켓 없음)" >> "$LOG"
echo "" >> "$LOG"

###########################
# 6) 입력장치(마우스/터치패드) 관련 검사
###########################
note "### 6) libinput / 입력장치 검사 (마우스 멈춤 관련)"
# libinput list-devices (있으면)
if check_cmd libinput libinput; then
  libinput list-devices > "${OUTDIR}/libinput_list_devices.log" 2>&1 || true
  echo "Saved libinput list to ${OUTDIR}/libinput_list_devices.log" >> "$LOG"
  
  # 입력 이벤트 테스트 (짧은 시간)
  timeout 5s libinput debug-events > "${OUTDIR}/libinput_debug_events.log" 2>&1 || true
  echo "Saved 5s libinput debug events to ${OUTDIR}/libinput_debug_events.log" >> "$LOG"
fi

journalctl -b --no-pager | grep -i libinput > "${OUTDIR}/libinput_journal.log" || true
echo "Saved libinput journal matches -> ${OUTDIR}/libinput_journal.log" >> "$LOG"

# 입력 장치 상태
echo "입력 장치 목록:" >> "$LOG"
ls -la /dev/input/ >> "$LOG" 2>/dev/null || true
echo "" >> "$LOG"

###########################
# 7) Vulkan / Mesa / ICD 검사
###########################
note "### 7) Vulkan / Mesa / ICD 검사"
if [ -d /usr/share/vulkan/icd.d ]; then
  ls -lah /usr/share/vulkan/icd.d > "${OUTDIR}/vulkan_icd_list.log" 2>&1 || true
  echo "Vulkan ICD files -> ${OUTDIR}/vulkan_icd_list.log" >> "$LOG"
  # ICD 파일 내용도 확인
  cat /usr/share/vulkan/icd.d/*.json > "${OUTDIR}/vulkan_icd_content.log" 2>&1 || true
fi

# vulkaninfo (있으면)
if check_cmd vulkaninfo vulkan-tools; then
  vulkaninfo > "${OUTDIR}/vulkaninfo_full.log" 2>&1 || true
  echo "Saved vulkaninfo -> ${OUTDIR}/vulkaninfo_full.log" >> "$LOG"
else
  echo "vulkaninfo not installed" >> "$LOG"
fi

# glxinfo
if check_cmd glxinfo mesa-demos; then
  glxinfo -B > "${OUTDIR}/glxinfo.log" 2>&1 || true
  echo "Saved glxinfo -> ${OUTDIR}/glxinfo.log" >> "$LOG"
fi

# Mesa 환경 변수 확인
echo "Mesa 관련 환경 변수:" >> "$LOG"
env | grep -i mesa >> "$LOG" || echo "(Mesa 환경 변수 없음)" >> "$LOG"
echo "" >> "$LOG"

###########################
# 8) 펌웨어/드라이버 로딩 문제 검사
###########################
note "### 8) 펌웨어 및 드라이버 로딩 검사"
dmesg | grep -i firmware > "${OUTDIR}/firmware_msgs.log" || true
dmesg | egrep -i 'amdgpu.*firmware|amdgpu.*failed|amdgpu.*error|amdgpu.*timeout' > "${OUTDIR}/amdgpu_dmesg.log" || true
journalctl -b --no-pager | egrep -i 'amdgpu.*firmware|amdgpu.*failed|amdgpu.*error|amdgpu.*timeout' > "${OUTDIR}/amdgpu_journal.log" || true

# 펌웨어 파일 존재 확인
echo "AMD 펌웨어 파일 상태:" >> "$LOG"
ls -la /lib/firmware/amdgpu/ 2>/dev/null | head -n 50 >> "$LOG" || echo "(amdgpu 펌웨어 디렉토리 없음)" >> "$LOG"
echo "Saved firmware & amdgpu related logs" >> "$LOG"
echo "" >> "$LOG"

###########################
# 9) 전원관리(DPM) / GPU 빈도 / 온도 (가능하면)
###########################
note "### 9) 전원관리(DPM) 및 온도/사용량 체크"
# pp_dpm_sclk / mclk / gpu_busy_percent 등 sysfs 체크
for card in /sys/class/drm/card*/device; do
  if [ -d "$card" ]; then
    cardpath=$(realpath "$card")
    echo "=== GPU Power Management: $cardpath ===" >> "${OUTDIR}/gpu_power_stats.log"
    
    # 다양한 DPM 설정 확인
    for file in pp_dpm_sclk pp_dpm_mclk power_dpm_state power_dpm_force_performance_level gpu_busy_percent; do
      if [ -r "$card/$file" ]; then
        echo "$file: $(cat "$card/$file" 2>/dev/null)" >> "${OUTDIR}/gpu_power_stats.log"
      fi
    done
    echo "" >> "${OUTDIR}/gpu_power_stats.log"
  fi
done
echo "Saved GPU power/stats -> ${OUTDIR}/gpu_power_stats.log" >> "$LOG"

# radeontop (있으면 짧은 샘플링)
if check_cmd radeontop radeontop; then
  timeout 10s radeontop -d - -l 5 > "${OUTDIR}/radeontop_sample.log" 2>&1 || true
  echo "Saved 10s radeontop sample -> ${OUTDIR}/radeontop_sample.log" >> "$LOG"
fi

# lm_sensors (있으면 온도 확인)
if check_cmd sensors lm_sensors; then
  sensors > "${OUTDIR}/sensors.log" 2>&1 || true
  echo "sensors output -> ${OUTDIR}/sensors.log" >> "$LOG"
else
  echo "lm_sensors(sensors) 미설치" >> "$LOG"
fi
echo "" >> "$LOG"

###########################
# 10) 코어덤 / 프로세스 충돌 검사
###########################
note "### 10) coredumpctl 및 프로세스 충돌 검사"
if check_cmd coredumpctl systemd; then
  coredumpctl list | head -n 100 > "${OUTDIR}/coredump_list_all.log" || true
  coredumpctl list | egrep -i 'gnome-shell|kwin|sway|weston|Xwayland|Xorg|compositor|pipewire' > "${OUTDIR}/coredump_list.log" || true
  echo "Saved coredump list -> ${OUTDIR}/coredump_list.log" >> "$LOG"
  
  # 최근 코어덤프 상세 정보 (최대 3개)
  coredumpctl list --no-pager | egrep -i 'gnome-shell|kwin|sway|weston|Xwayland|Xorg' | head -n 3 | while read line; do
    pid=$(echo "$line" | awk '{print $5}')
    if [ -n "$pid" ]; then
      coredumpctl info "$pid" >> "${OUTDIR}/coredump_details.log" 2>&1 || true
    fi
  done
else
  echo "coredumpctl 명령 없음" >> "$LOG"
fi
echo "" >> "$LOG"

###########################
# 11) 네트워크 및 성능 관련
###########################
note "### 11) 시스템 성능 및 메모리 상태"
free -h > "${OUTDIR}/memory_usage.log"
uptime >> "${OUTDIR}/memory_usage.log"
cat /proc/loadavg >> "${OUTDIR}/memory_usage.log"
echo "Saved system performance stats -> ${OUTDIR}/memory_usage.log" >> "$LOG"

# 메모리 부족 관련 로그
dmesg | grep -i "out of memory\|oom\|killed process" > "${OUTDIR}/oom_logs.log" || true
journalctl -b --no-pager | grep -i "out of memory\|oom\|killed process" >> "${OUTDIR}/oom_logs.log" || true
echo "Saved OOM related logs -> ${OUTDIR}/oom_logs.log" >> "$LOG"

###########################
# 12) 반복적/루프성 오류 검색
###########################
note "### 12) 반복적으로 많이 발생한 로그 항목 (Top 50)"
journalctl -b --no-pager | awk '{$1=$2=$3=""; print $0}' | sed 's/^[[:space:]]*//' | sort | uniq -c | sort -nr | head -n 50 > "${OUTDIR}/journal_top50.log" || true
echo "Saved top50 repeated journal lines -> ${OUTDIR}/journal_top50.log" >> "$LOG"
echo "" >> "$LOG"

###########################
# 13) 심각한 항목 요약 (SUMMARY)
###########################
note "### 13) 심각 항목 요약 생성"
: > "$SUMMARY"
echo "GPU 진단 요약 (Enhanced) - 생성시간: $(timestamp)" >> "$SUMMARY"
echo "사용자: $(whoami), 호스트: $(hostname)" >> "$SUMMARY"
echo "세션: ${XDG_SESSION_TYPE:-unknown}, 데스크톱: ${XDG_CURRENT_DESKTOP:-unknown}" >> "$SUMMARY"
echo "" >> "$SUMMARY"

# 심각(에러/failed/oops/hang 등)
echo "== CRITICAL matches (dmesg/journal)" >> "$SUMMARY"
grep -iE 'error|fail|failed|panic|oops|GPU hang|gpu fault|segfault|traceback|call trace' "${OUTDIR}/dmesg_keywords.log" 2>/dev/null | head -n 50 >> "$SUMMARY" || true
journalctl -b --no-pager | egrep -i 'amdgpu.*(error|failed|hang|fault|timeout)|GPU hang|GPU fault|kernel panic|segfault' | head -n 30 >> "$SUMMARY" 2>/dev/null || true

echo "" >> "$SUMMARY"
echo "== WARNING matches (libinput / compositor / XWayland / firmware warnings)" >> "$SUMMARY"
cat "${OUTDIR}/journal_keywords.log" 2>/dev/null | egrep -i 'warn|deprecated|fail|timeout' | head -n 50 >> "$SUMMARY" || true

echo "" >> "$SUMMARY"
echo "== GPU/Driver Status" >> "$SUMMARY"
lsmod | grep -E 'amdgpu|radeon|drm' >> "$SUMMARY" || echo "No GPU modules loaded" >> "$SUMMARY"

echo "" >> "$SUMMARY"
echo "== Memory/OOM Issues" >> "$SUMMARY"
head -n 20 "${OUTDIR}/oom_logs.log" >> "$SUMMARY" 2>/dev/null || echo "No OOM issues found" >> "$SUMMARY"

echo "" >> "$SUMMARY"
echo "== Top repeated messages (journal top50)" >> "$SUMMARY"
head -n 20 "${OUTDIR}/journal_top50.log" >> "$SUMMARY" || true

echo "" >> "$SUMMARY"
echo "== 추가 수집 파일 (전체 목록)" >> "$SUMMARY"
ls -lah "$OUTDIR" >> "$SUMMARY"

###########################
# 14) HTML 보고서 생성 (선택적)
###########################
note "### 14) HTML 보고서 생성"
cat > "$REPORT" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>GPU 진단 보고서</title>
    <style>
        body { font-family: monospace; margin: 20px; background: #1e1e1e; color: #d4d4d4; }
        .header { background: #2d2d30; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .section { background: #252526; padding: 10px; margin: 10px 0; border-radius: 5px; }
        .critical { color: #f44747; }
        .warning { color: #ffcc02; }
        .info { color: #4ec9b0; }
        pre { background: #1e1e1e; padding: 10px; border-radius: 3px; overflow-x: auto; }
        h2 { color: #569cd6; border-bottom: 2px solid #569cd6; }
        h3 { color: #4ec9b0; }
    </style>
</head>
<body>
EOF

echo "<div class='header'>" >> "$REPORT"
echo "<h1>GPU 진단 보고서</h1>" >> "$REPORT"
echo "<p><strong>생성 시간:</strong> $(timestamp)</p>" >> "$REPORT"
echo "<p><strong>시스템:</strong> $(uname -a)</p>" >> "$REPORT"
echo "<p><strong>세션:</strong> ${XDG_SESSION_TYPE:-unknown} / ${XDG_CURRENT_DESKTOP:-unknown}</p>" >> "$REPORT"
echo "</div>" >> "$REPORT"

echo "<div class='section'>" >> "$REPORT"
echo "<h2>요약</h2>" >> "$REPORT"
echo "<pre>" >> "$REPORT"
head -n 100 "$SUMMARY" >> "$REPORT"
echo "</pre>" >> "$REPORT"
echo "</div>" >> "$REPORT"

echo "<div class='section'>" >> "$REPORT"
echo "<h2>수집된 파일</h2>" >> "$REPORT"
echo "<ul>" >> "$REPORT"
for file in "$OUTDIR"/*.log; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        size=$(stat -c%s "$file" 2>/dev/null || echo "0")
        echo "<li><strong>$filename</strong> (${size} bytes)</li>" >> "$REPORT"
    fi
done
echo "</ul>" >> "$REPORT"
echo "</div>" >> "$REPORT"

echo "</body></html>" >> "$REPORT"
info "HTML 보고서 생성 완료: $REPORT"

# 화면에 핵심 출력
echo ""
echo "=== 검사 완료 (Enhanced Version) ==="
echo "로그 전체는: $OUTDIR 에 저장되었습니다."
echo "요약 파일: $SUMMARY"
echo "HTML 보고서: $REPORT"
echo ""
echo "중대한 에러(있을 경우) 상위 출력:"
# show a few lines of summary critical part
grep -iE 'CRITICAL:|GPU hang|GPU fault|panic|oops|segfault|amdgpu.*failed|amdgpu.*error|amdgpu.*timeout' "${OUTDIR}/dmesg_keywords.log" "${OUTDIR}/amdgpu_journal.log" "${OUTDIR}/journal_keywords.log" 2>/dev/null | head -n 20 || echo "심각한 오류가 발견되지 않았습니다."

echo ""
echo "실행이 완료되었습니다. 생성된 파일들을 포럼이나 이슈에 첨부하면 문제 해결에 도움이 됩니다."
echo ""
echo "권장 추가조치:"
echo "- 생성된 ${OUTDIR} 전체를 tar.gz로 묶어 첨부:"
echo "  tar czf gpu_report_$(date +%Y%m%d_%H%M%S).tgz -C ~/ gpu_full_diagnose"
echo "- compositor(gnome-shell/kwin) 충돌이 보이면 'coredumpctl info <PID>' 또는 해당 로그를 첨부"
echo "- amdgpu firmware 관련 메시지가 있으면 사용중인 커널 버전 및 dmesg 출력을 함께 첨부"
echo "- HTML 보고서를 브라우저에서 열어 더 쉽게 확인 가능"
echo ""
echo "실시간 모니터링이 필요한 경우:"
echo "- journalctl -f | grep -i 'amdgpu\|gpu\|hang\|error'"
echo "- watch -n 1 'dmesg | tail -n 20'"
if command -v radeontop >/dev/null 2>&1; then
    echo "- radeontop (GPU 사용량 실시간 모니터링)"
fi
