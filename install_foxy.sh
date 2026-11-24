#!/usr/bin/env bash
# install_foxy.sh — installer for unitree_converse on the G1's Jetson
# (Ubuntu 20.04, ROS 2 Foxy), written to be safe on a robot that is already in
# use. It is the Foxy counterpart of install_jetson.sh (which targets 22.04).
#
# Guarantees, enforced in code rather than promised in prose:
#   * apt is simulated first; if a step would REMOVE or UPGRADE anything, that
#     step is refused and reported instead of run (override: --allow-apt-changes).
#   * No systemd unit is ever enabled. Ollama is only installed with --with-ollama
#     and is left as a manual `ollama serve`.
#   * Repository files are never edited unless --allow-repo-edits is given; when
#     it is, a .bak is written and the revert command is printed.
#   * Nothing is sent to the robot. Only audio playback is ever exercised, and
#     only by the manual command printed at the end.
#   * Works with no internet: --offline (with --bundle DIR) skips every download
#     and verifies what is already on disk.
#
# Usage:
#   ./install_foxy.sh                      # report only (changes nothing)
#   ./install_foxy.sh --install            # check -> ask -> install -> verify
#   ./install_foxy.sh --install --offline --bundle ~/unitree_offline_bundle
#   ./install_foxy.sh --verify             # verification only
#
# Bundle layout (only what you actually have; missing items become manual steps):
#   $BUNDLE/piper_linux_aarch64.tar.gz    Piper aarch64 release
#   $BUNDLE/voices/en_US-lessac-medium.onnx{,.json}
#   $BUNDLE/wheels/*.whl                  pip wheels for the Python deps
#
# Exit codes: 0 ok, 1 blocked, 2 verification failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/unitree_converse_foxy_$(date +%Y%m%d_%H%M%S).log"

MODE="check"
ASSUME_YES=0
OFFLINE=0
BUNDLE=""
ALLOW_APT_CHANGES=0
ALLOW_REPO_EDITS=0
WITH_OLLAMA=0

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  arg="$1"; shift
  case "$arg" in
    --check)              MODE="check" ;;
    --install)            MODE="install" ;;
    --verify)             MODE="verify" ;;
    --offline)            OFFLINE=1 ;;
    --bundle)             BUNDLE="${1:-}"; [ "$#" -gt 0 ] && shift ;;
    --bundle=*)           BUNDLE="${arg#*=}" ;;
    --allow-apt-changes)  ALLOW_APT_CHANGES=1 ;;
    --allow-repo-edits)   ALLOW_REPO_EDITS=1 ;;
    --with-ollama)        WITH_OLLAMA=1 ;;
    --yes|-y)             ASSUME_YES=1 ;;
    --help|-h)            usage; exit 0 ;;
    *) echo "Unknown option: $arg (use --help)"; exit 1 ;;
  esac
done

if [ "$OFFLINE" -eq 0 ] && [ -z "$BUNDLE" ]; then
  for d in "$REPO_DIR/offline_bundle" "$HOME/unitree_offline_bundle"; do
    if [ -d "$d" ]; then BUNDLE="$d"; break; fi
  done
fi
[ -n "$BUNDLE" ] && [ ! -d "$BUNDLE" ] && { echo "Bundle directory not found: $BUNDLE"; exit 1; }

# ── output helpers ──────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HDR=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_HDR=""; C_OFF=""
fi

section() { printf '\n%s== %s ==%s\n' "$C_HDR" "$1" "$C_OFF"; }
ok()      { printf '%s  ok %s %s\n' "$C_OK" "$C_OFF" "$1"; }
warn()    { printf '%s warn%s %s\n' "$C_WARN" "$C_OFF" "$1"; WARNINGS+=("$1"); }
fail()    { printf '%s fail%s %s\n' "$C_ERR" "$C_OFF" "$1"; BLOCKERS+=("$1"); }
info()    { printf '  ...  %s\n' "$1"; }
note()    { printf '       %s\n' "$1"; }
manual()  { MANUAL+=("$1"); }

BLOCKERS=(); WARNINGS=(); MANUAL=(); RESULTS=(); FAILED=0

run() { "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"; }

SUDO=""
[ "$EUID" -ne 0 ] && SUDO="sudo"

OS_VER=""; ARCH="$(uname -m)"; ROS_DISTRO_FOUND=""
ROBOT_IFACE=""; ROBOT_IP=""; HAVE_INTERNET=0; CLOCK_OK=1

# ── 1. system ───────────────────────────────────────────────────────────────
detect_system() {
  section "1. System"
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_VER="${VERSION_ID:-}"
  fi
  if [ "$OS_VER" = "20.04" ]; then
    ok "Ubuntu 20.04 ($ARCH)"
  else
    warn "Ubuntu ${OS_VER:-unknown}; this script targets the G1 Jetson image (20.04 + Foxy)."
  fi

  if [ -r /proc/device-tree/model ]; then
    ok "Board: $(tr -d '\0' < /proc/device-tree/model)"
  else
    warn "No Jetson device tree found — this does not look like a Jetson."
  fi

  [ "$ARCH" = "aarch64" ] && ok "Architecture: aarch64" \
    || warn "Architecture is $ARCH, not aarch64: the aarch64 Piper binary will not run."

  local free_mb
  free_mb="$(df -Pm "$HOME" | awk 'NR==2 {print $4}')"
  [ "${free_mb:-0}" -lt 6000 ] && warn "Only ${free_mb} MB free in \$HOME; models and builds need ~6 GB." \
    || ok "Free space in \$HOME: ${free_mb} MB"

  [ "$(id -un)" = "unitree" ] && ok "User: unitree" \
    || warn "Running as '$(id -un)'. Project config expects /home/unitree paths."

  # A wrong clock breaks every HTTPS download with a certificate error.
  local year
  year="$(date +%Y)"
  if [ "$year" -lt 2024 ]; then
    CLOCK_OK=0
    local clock_msg="System clock reads $(date '+%Y-%m-%d %H:%M') — every HTTPS download fails with a certificate error until it is correct."
    # An online install cannot proceed with a 1970 clock; an offline one does not care.
    if [ "$OFFLINE" -eq 1 ]; then
      warn "$clock_msg"
    else
      fail "$clock_msg"
    fi
    note "Fix first:  sudo date -s 'YYYY-MM-DD HH:MM:SS'   (or: sudo timedatectl set-ntp true)"
    note "Then re-run this script — or add --offline to install from a local bundle."
  else
    ok "Clock: $(date '+%Y-%m-%d %H:%M')"
  fi
}

# ── 2. ROS 2 ────────────────────────────────────────────────────────────────
detect_ros() {
  section "2. ROS 2"
  local d
  for d in foxy humble jazzy; do
    if [ -d "/opt/ros/$d" ]; then ROS_DISTRO_FOUND="$d"; break; fi
  done

  if [ -z "$ROS_DISTRO_FOUND" ]; then
    fail "No ROS 2 installation in /opt/ros. On the G1 image Foxy should already be there."
    return
  fi
  if [ "$ROS_DISTRO_FOUND" = "foxy" ]; then
    ok "ROS 2 Foxy found (matches the robot image)"
  else
    warn "Found ROS 2 $ROS_DISTRO_FOUND, not Foxy. Robot packages must be built for the same distro; continue only if you know the robot image uses it."
  fi

  [ -f "/opt/ros/$ROS_DISTRO_FOUND/setup.bash" ] && ok "setup.bash present" \
    || fail "/opt/ros/$ROS_DISTRO_FOUND/setup.bash missing — the ROS 2 install looks incomplete."

  # shellcheck disable=SC1090
  set +u; source "/opt/ros/$ROS_DISTRO_FOUND/setup.bash" 2>/dev/null; set -u
  command -v colcon >/dev/null 2>&1 && ok "colcon available" || warn "colcon not installed."
  ros2 pkg prefix rmw_cyclonedds_cpp >/dev/null 2>&1 && ok "CycloneDDS RMW available" \
    || warn "rmw_cyclonedds_cpp not found (ros-$ROS_DISTRO_FOUND-rmw-cyclonedds-cpp)."
}

# ── 3. network ──────────────────────────────────────────────────────────────
probe_internet() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 6 -o /dev/null https://github.com 2>/dev/null && return 0
    curl -fsS --max-time 6 -o /dev/null https://pypi.org 2>/dev/null && return 0
    return 1
  fi
  python3 - 2>/dev/null <<'PY'
import socket, sys
for host in ("github.com", "pypi.org"):
    try:
        socket.create_connection((host, 443), timeout=5).close()
        sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PY
}

detect_network() {
  section "3. Network"
  if probe_internet; then
    HAVE_INTERNET=1
    ok "Internet reachable"
  else
    HAVE_INTERNET=0
    if [ "$CLOCK_OK" -eq 0 ]; then
      warn "No internet — the clock is wrong, which alone breaks HTTPS. Fix the clock, then retest."
    elif ! getent hosts github.com >/dev/null 2>&1; then
      warn "No internet and DNS resolution fails. Check the cable/router, then: cat /etc/resolv.conf"
    else
      warn "No internet access. Run with --offline to install from a local bundle."
    fi
  fi

  ROBOT_IP="$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.123\./ {sub(/\/.*/,"",$4); print $2, $4; exit}')"
  if [ -n "$ROBOT_IP" ]; then
    ROBOT_IFACE="${ROBOT_IP%% *}"
    ok "Robot LAN: ${ROBOT_IFACE} has ${ROBOT_IP#* }"
    [ "$ROBOT_IFACE" != "eth0" ] && warn "Robot link is on '$ROBOT_IFACE', not eth0 (tts_node hardcodes eth0)."
    ip -4 -o addr show 2>/dev/null | grep -q "192\.168\.123\.164/" \
      && ok "Jetson 192.168.123.164 present (stt_node udp_local_ip)" \
      || warn "Jetson is not 192.168.123.164, which voice_params_real.yaml expects for the mic."
  else
    warn "No 192.168.123.x interface — connect the Ethernet cable to the robot before running the pipeline."
  fi
}

# ── 4. apt guard: refuse removals and upgrades ──────────────────────────────
apt_block_list() { # apt_block_list <marker> <simulation output>
  printf '%s\n' "$2" | awk -v m="$1" '
    $0 ~ m {f=1; next}
    f && /^ / {gsub(/^ +| +$/,""); print; next}
    {f=0}' | tr '\n' ' ' | sed 's/ *$//'
}

apt_simulate() { # apt_simulate <pkgs...> -> sets APT_NEW/APT_UPGRADE/APT_REMOVE/APT_SIM_RC
  local out
  out="$($SUDO apt-get -s install -y "$@" 2>&1)"
  APT_SIM_RC=$?
  APT_REMOVE="$(apt_block_list 'will be REMOVED' "$out")"
  APT_UPGRADE="$(apt_block_list 'will be upgraded' "$out")"
  APT_NEW="$(apt_block_list 'NEW packages will be installed' "$out")"
}

apt_install_guarded() { # apt_install_guarded <label> <pkgs...>
  local label="$1"; shift
  apt_simulate "$@"
  if [ "${APT_SIM_RC:-0}" -ne 0 ]; then
    warn "$label: apt cannot resolve these packages right now (offline or stale package lists)"
    note "Not installing. Update package lists when online, or install by hand: sudo apt-get install $*"
    return 3
  fi
  if [ -n "$APT_REMOVE" ] || [ -n "$APT_UPGRADE" ]; then
    if [ "$ALLOW_APT_CHANGES" -eq 1 ]; then
      warn "$label: proceeding although apt would remove/upgrade packages (--allow-apt-changes)"
    else
      warn "$label: refused — apt would change packages you did not ask for"
      [ -n "$APT_REMOVE" ]  && note "would REMOVE:  $APT_REMOVE"
      [ -n "$APT_UPGRADE" ] && note "would UPGRADE: $APT_UPGRADE"
      note "Not running it. Install these by hand if you accept the change, or pass --allow-apt-changes."
      return 3
    fi
  fi
  if [ -z "$APT_NEW" ] && [ -z "$APT_UPGRADE" ]; then
    ok "$label: already satisfied"
    return 0
  fi
  info "$label: installing $APT_NEW"
  if $SUDO apt-get install -y --no-remove --no-upgrade "$@" >>"$LOG_FILE" 2>&1; then
    ok "$label installed"
    return 0
  fi
  warn "$label: install failed (see $LOG_FILE)"
  return 1
}

step_apt() {
  section "5. System packages (no removals, no upgrades)"

  if [ "$HAVE_INTERNET" -eq 0 ] || [ "$OFFLINE" -eq 1 ]; then
    info "Offline: apt is not updated; only already-cached packages can install"
  else
    if ! $SUDO apt-get update >>"$LOG_FILE" 2>&1; then
      warn "apt-get update failed — continuing with the existing package lists"
    fi
  fi

  # Runtime pieces only. portaudio19-dev is deliberately NOT here: on some
  # images it conflicts with libjack-jackd2-0, and sounddevice needs only the
  # runtime library.
  local core=(sox libsndfile1 python3-pip python3-yaml build-essential cmake git curl)
  if apt_install_guarded "core packages" "${core[@]}"; then
    :
  else
    # Fall back to one package at a time so one conflict cannot block the rest.
    local p
    for p in "${core[@]}"; do
      apt_install_guarded "$p" "$p" >/dev/null 2>&1 || manual "Install '$p' by hand (apt refused it without removing/upgrading packages)."
    done
  fi

  apt_install_guarded "audio runtime (libportaudio2)" libportaudio2 \
    || manual "sounddevice needs libportaudio2: sudo apt-get install libportaudio2"

  if [ -n "$ROS_DISTRO_FOUND" ]; then
    apt_install_guarded "ROS packages" \
      "ros-${ROS_DISTRO_FOUND}-rmw-cyclonedds-cpp" \
      "ros-${ROS_DISTRO_FOUND}-ament-cmake-python" \
      python3-colcon-common-extensions \
      || manual "Install ros-${ROS_DISTRO_FOUND}-rmw-cyclonedds-cpp, ros-${ROS_DISTRO_FOUND}-ament-cmake-python and python3-colcon-common-extensions by hand."
  fi
}

# ── 6. Python dependencies ──────────────────────────────────────────────────
step_python() {
  section "6. Python dependencies"
  local mods="faster_whisper sounddevice soundfile openwakeword numpy tqdm filelock requests"
  local m missing=""
  for m in $mods; do
    python3 -c "import $m" >/dev/null 2>&1 || missing="$missing $m"
  done
  if [ -z "$missing" ]; then
    ok "Python modules already importable"
    return 0
  fi

  # --user keeps the robot's system Python (and its ROS packages) untouched.
  local args=(--user faster-whisper sounddevice soundfile tqdm filelock openwakeword numpy requests)
  if [ "$OFFLINE" -eq 1 ] || [ "$HAVE_INTERNET" -eq 0 ]; then
    if [ -n "$BUNDLE" ] && [ -d "$BUNDLE/wheels" ]; then
      info "Installing from $BUNDLE/wheels"
      if python3 -m pip install --user --no-index --find-links "$BUNDLE/wheels" "${args[@]:1}" >>"$LOG_FILE" 2>&1; then
        ok "Python dependencies installed from bundle"
        return 0
      fi
    fi
    warn "Offline and no usable wheel bundle:$missing"
    manual "Install the Python deps offline: python3 -m pip install --user --no-index --find-links <dir> faster-whisper sounddevice soundfile tqdm filelock openwakeword numpy requests"
    return 1
  fi

  info "pip install --user$missing"
  if python3 -m pip install "${args[@]}" >>"$LOG_FILE" 2>&1; then
    ok "Python dependencies installed"
  else
    warn "pip install failed (see $LOG_FILE)"
    manual "Install the Python deps by hand: python3 -m pip install --user faster-whisper sounddevice soundfile tqdm filelock openwakeword numpy requests"
    return 1
  fi
}

# ── 7. Piper + voice model ──────────────────────────────────────────────────
step_piper() {
  section "7. Piper (text to speech)"
  local voice_dir="$HOME/.local/share/piper"

  if command -v piper >/dev/null 2>&1; then
    ok "piper binary present ($(command -v piper))"
  elif [ -n "$BUNDLE" ] && [ -f "$BUNDLE/piper_linux_aarch64.tar.gz" ]; then
    local tmp; tmp="$(mktemp -d)"
    if tar -xzf "$BUNDLE/piper_linux_aarch64.tar.gz" -C "$tmp" >>"$LOG_FILE" 2>&1 \
       && $SUDO install -m 0755 "$tmp/piper/piper" /usr/local/bin/piper; then
      ok "piper installed from bundle"
    else
      warn "Could not unpack $BUNDLE/piper_linux_aarch64.tar.gz"
      manual "Unpack the Piper aarch64 release and put the 'piper' binary on PATH."
    fi
    rm -rf "$tmp"
  elif [ "$HAVE_INTERNET" -eq 1 ] && [ "$OFFLINE" -eq 0 ]; then
    if [ "$ARCH" != "aarch64" ]; then
      warn "Skipping Piper: the release binary is aarch64-only"
      manual "Build Piper from source or run the pipeline on the Jetson."
    else
      local tmp; tmp="$(mktemp -d)"
      info "Downloading Piper aarch64"
      if curl -fsSL -o "$tmp/piper.tar.gz" \
          https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_aarch64.tar.gz >>"$LOG_FILE" 2>&1 \
         && tar -xzf "$tmp/piper.tar.gz" -C "$tmp" >>"$LOG_FILE" 2>&1 \
         && $SUDO install -m 0755 "$tmp/piper/piper" /usr/local/bin/piper; then
        ok "piper installed at /usr/local/bin/piper"
      else
        warn "Piper download/install failed"
        manual "Download piper_linux_aarch64.tar.gz and install the 'piper' binary."
      fi
      rm -rf "$tmp"
    fi
  else
    warn "Offline and no Piper binary or bundle"
    manual "Put the Piper aarch64 binary on PATH (bundle it as piper_linux_aarch64.tar.gz)."
  fi

  mkdir -p "$voice_dir"
  local f
  for f in en_US-lessac-medium.onnx en_US-lessac-medium.onnx.json; do
    if [ -f "$voice_dir/$f" ]; then
      ok "Voice model $f present"
    elif [ -n "$BUNDLE" ] && [ -f "$BUNDLE/voices/$f" ]; then
      cp "$BUNDLE/voices/$f" "$voice_dir/$f" && ok "Voice model $f copied from bundle"
    elif [ "$HAVE_INTERNET" -eq 1 ] && [ "$OFFLINE" -eq 0 ]; then
      info "Downloading $f"
      curl -fsSL -o "$voice_dir/$f" \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/$f" >>"$LOG_FILE" 2>&1 \
        && ok "Voice model $f downloaded" \
        || { warn "Voice model $f download failed"; manual "Place $f in $voice_dir."; }
    else
      warn "Voice model $f missing and no bundle copy"
      manual "Place $f in $voice_dir (bundle it as voices/$f)."
    fi
  done
}

# ── 8. faster-whisper model ─────────────────────────────────────────────────
step_whisper_model() {
  section "8. Speech recognition model"
  if python3 -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8', local_files_only=True)" >/dev/null 2>&1; then
    ok "faster-whisper 'base' already cached"
    return 0
  fi
  if [ "$HAVE_INTERNET" -eq 1 ] && [ "$OFFLINE" -eq 0 ]; then
    info "Downloading faster-whisper 'base' (CPU int8)"
    if python3 -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8')" >>"$LOG_FILE" 2>&1; then
      ok "faster-whisper base cached"
      return 0
    fi
    warn "faster-whisper download failed"
  else
    warn "Offline and the 'base' model is not cached"
  fi
  manual "Cache the whisper model offline: copy the HF snapshot into ~/.cache/huggingface, or run python3 -c \"from faster_whisper import WhisperModel; WhisperModel('base')\" once with internet."
}

# ── 9. Ollama (opt-in, never enabled) ───────────────────────────────────────
step_ollama() {
  section "9. Local language model (Ollama + llama3.2)"
  if [ "$WITH_OLLAMA" -eq 0 ]; then
    if command -v ollama >/dev/null 2>&1; then
      ok "Ollama present (not touched: no service was enabled or started)"
    else
      info "Skipped — pass --with-ollama to install it"
      manual "Install Ollama when you want the LLM locally: curl -fsSL https://ollama.com/install.sh | sh   (then: ollama serve & ollama pull llama3.2)"
    fi
    return 0
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    if [ "$HAVE_INTERNET" -eq 0 ] || [ "$OFFLINE" -eq 1 ]; then
      warn "Ollama is not installed and this is an offline run"
      manual "Install Ollama from the bundle/installer, then: ollama serve & ollama pull llama3.2"
      return 1
    fi
    info "Installing Ollama (its script may enable a service; it is disabled again below)"
    if ! curl -fsSL https://ollama.com/install.sh | sh >>"$LOG_FILE" 2>&1; then
      warn "Ollama install failed"
      manual "Install Ollama by hand."
      return 1
    fi
  fi
  ok "Ollama installed"

  # The vendor script enables ollama.service. Undo that: no auto-start on a robot.
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ollama.service >/dev/null 2>&1; then
    if systemctl is-enabled ollama.service >/dev/null 2>&1; then
      $SUDO systemctl disable ollama.service >>"$LOG_FILE" 2>&1 \
        && ok "ollama.service auto-start disabled (it had been enabled by the vendor script)" \
        || warn "Could not disable ollama.service — check: systemctl is-enabled ollama.service"
    else
      ok "ollama.service is not enabled at boot"
    fi
  fi

  if [ "$HAVE_INTERNET" -eq 1 ] && [ "$OFFLINE" -eq 0 ]; then
    if ! curl -fsS --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
      info "Starting ollama serve in the background for this session only"
      nohup ollama serve >>"$LOG_FILE" 2>&1 &
      local i
      for i in $(seq 1 20); do
        curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1 && break
        sleep 1
      done
    fi
    info "Pulling llama3.2 (about 2 GB)"
    ollama pull llama3.2 >>"$LOG_FILE" 2>&1 && ok "llama3.2 available" \
      || { warn "ollama pull llama3.2 failed"; manual "Run: ollama pull llama3.2"; }
  else
    manual "Pull the model when online: ollama pull llama3.2"
  fi
}

# ── 10. bob_llm ─────────────────────────────────────────────────────────────
# bob_llm ships llm_node.py with no shebang and no executable bit; launch_ros
# runs it directly, so it fails with "Exec format error". The fix edits a
# repository file, so it only happens with --allow-repo-edits.
step_submodule() {
  section "10. LLM ROS package (bob_llm)"
  if [ -z "$(ls -A "$REPO_DIR/src/bob_llm" 2>/dev/null)" ]; then
    if [ "$HAVE_INTERNET" -eq 0 ] || [ "$OFFLINE" -eq 1 ]; then
      warn "src/bob_llm is empty and this is an offline run"
      manual "Populate src/bob_llm: git -C $REPO_DIR submodule update --init --recursive"
      return 1
    fi
    info "Fetching bob_llm"
    if ! git -C "$REPO_DIR" submodule update --init --recursive >>"$LOG_FILE" 2>&1; then
      local target="$REPO_DIR/src/bob_llm" tmpc="$REPO_DIR/src/.bob_llm_clone"
      rm -rf "$tmpc"
      if git clone --depth 1 https://github.com/AkhileshSingh01/bob_llm.git "$tmpc" >>"$LOG_FILE" 2>&1; then
        rm -rf "$target"; mv "$tmpc" "$target"
        ok "bob_llm cloned from the public fork"
      else
        rm -rf "$tmpc"
        warn "Could not fetch bob_llm"
        manual "Clone bob_llm into src/bob_llm."
        return 1
      fi
    else
      ok "bob_llm submodule initialised"
    fi
  else
    ok "src/bob_llm already populated"
  fi

  local node="$REPO_DIR/src/bob_llm/bob_llm/llm_node.py"
  if [ ! -f "$node" ]; then
    warn "src/bob_llm/bob_llm/llm_node.py not found"
    return 1
  fi
  local first; first="$(head -1 "$node")"
  case "$first" in
    '#!'*) ok "LLM node already has a shebang" ;;
    *)
      if [ "$ALLOW_REPO_EDITS" -eq 0 ]; then
        warn "LLM node has no shebang; not editing the repository without --allow-repo-edits"
        manual "Either re-run with --allow-repo-edits, or launch with: python3 src/bob_llm/bob_llm/llm_node.py"
      else
        cp -p "$node" "$node.bak"
        { echo '#!/usr/bin/env python3'; cat "$node.bak"; } > "$node"
        ok "Added the shebang to llm_node.py (backup: llm_node.py.bak)"
        note "Revert with: mv $node.bak $node"
      fi
      ;;
  esac
  chmod +x "$REPO_DIR"/src/bob_llm/bob_llm/*.py 2>/dev/null || true
}

# ── 11. unitree_ros2 messages ───────────────────────────────────────────────
step_unitree_ros2() {
  section "11. Unitree robot messages"
  if ros2 pkg prefix unitree_go >/dev/null 2>&1 && ros2 pkg prefix unitree_hg >/dev/null 2>&1; then
    ok "unitree_go / unitree_hg already available"
    return 0
  fi
  local dir="$HOME/unitree_ros2"
  if [ ! -d "$dir" ]; then
    if [ "$HAVE_INTERNET" -eq 0 ] || [ "$OFFLINE" -eq 1 ]; then
      warn "unitree_ros2 is not cloned and this is an offline run"
      manual "Clone https://github.com/unitreerobotics/unitree_ros2 into ~/unitree_ros2 and build unitree_go, unitree_api, unitree_hg."
      return 1
    fi
    git clone --depth 1 https://github.com/unitreerobotics/unitree_ros2.git "$dir" >>"$LOG_FILE" 2>&1 \
      || { warn "unitree_ros2 clone failed"; manual "Clone unitree_ros2 manually."; return 1; }
  fi
  info "Building unitree_go, unitree_api, unitree_hg for $ROS_DISTRO_FOUND"
  (
    set +u
    source "/opt/ros/$ROS_DISTRO_FOUND/setup.bash"
    cd "$dir/cyclonedds_ws" || exit 1
    colcon build --packages-select unitree_go unitree_api unitree_hg
  ) >>"$LOG_FILE" 2>&1
  if ros2 pkg prefix unitree_go >/dev/null 2>&1; then
    ok "Unitree messages built"
  else
    warn "Unitree message build failed (see $LOG_FILE)"
    manual "Build unitree_ros2/cyclonedds_ws by hand."
    return 1
  fi
}

# ── 12. CycloneDDS config ───────────────────────────────────────────────────
step_cyclonedds_config() {
  section "12. DDS interface config"
  local cfg="$HOME/cyclonedds_ws/cyclonedds.xml"
  if [ -f "$cfg" ]; then
    ok "cyclonedds.xml already present (left untouched)"
    return 0
  fi
  local iface="${ROBOT_IFACE:-eth0}"
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<EOF
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="any">
    <General>
      <Interfaces>
        <NetworkInterface name="$iface" priority="default" multicast="default" />
      </Interfaces>
      <AllowMulticast>default</AllowMulticast>
    </General>
  </Domain>
</CycloneDDS>
EOF
  ok "Wrote $cfg using interface '$iface'"
  [ -z "$ROBOT_IFACE" ] && warn "No robot interface detected; the file defaults to eth0 — adjust it after connecting the cable."
}

# ── 13. g1_piper_tts speaker bridge ─────────────────────────────────────────
step_tts_bridge() {
  section "13. Speaker bridge (g1_piper_tts)"
  local sdk="$HOME/unitree_sdk2_latest"
  local bin="$sdk/build/bin/g1_piper_tts"
  local src="$REPO_DIR/tools/g1_piper_tts/g1_piper_tts.cpp"

  if [ -x "$bin" ]; then
    ok "g1_piper_tts already built ($bin)"
    return 0
  fi
  if [ ! -f "$src" ]; then
    warn "tools/g1_piper_tts/g1_piper_tts.cpp missing from this checkout"
    manual "Get the speaker bridge source: tools/g1_piper_tts/g1_piper_tts.cpp"
    return 1
  fi
  if [ ! -d "$sdk" ]; then
    if [ "$HAVE_INTERNET" -eq 0 ] || [ "$OFFLINE" -eq 1 ]; then
      warn "unitree_sdk2 not present and this is an offline run"
      manual "Clone unitree_sdk2 into ~/unitree_sdk2_latest, then re-run --install."
      return 1
    fi
    info "Cloning unitree_sdk2"
    git clone --depth 1 https://github.com/unitreerobotics/unitree_sdk2.git "$sdk" >>"$LOG_FILE" 2>&1 \
      || { warn "unitree_sdk2 clone failed"; manual "Clone unitree_sdk2 into ~/unitree_sdk2_latest."; return 1; }
  fi

  mkdir -p "$sdk/example/g1/audio"
  cp "$src" "$sdk/example/g1/audio/g1_piper_tts.cpp"
  local cmake="$sdk/example/g1/CMakeLists.txt"
  if ! grep -q 'add_executable(g1_piper_tts' "$cmake" 2>/dev/null; then
    printf '\nadd_executable(g1_piper_tts audio/g1_piper_tts.cpp)\ntarget_link_libraries(g1_piper_tts unitree_sdk2)\n' >> "$cmake"
    ok "Registered the g1_piper_tts target in unitree_sdk2"
  fi

  info "Building g1_piper_tts (this compiles the SDK the first time)"
  if ( cd "$sdk/build" 2>/dev/null || { mkdir -p "$sdk/build" && cd "$sdk/build"; }; cmake .. && make g1_piper_tts -j"$(nproc)" ) >>"$LOG_FILE" 2>&1; then
    if [ -x "$bin" ]; then
      ok "g1_piper_tts built at $bin"
      return 0
    fi
  fi
  warn "g1_piper_tts build failed (see $LOG_FILE)"
  manual "Build it by hand: cd ~/unitree_sdk2_latest/build && cmake .. && make g1_piper_tts -j\$(nproc)"
  return 1
}

# ── 14. workspace build ─────────────────────────────────────────────────────
step_build_workspace() {
  section "14. ROS 2 workspace build"
  info "colcon build --symlink-install in $REPO_DIR"
  (
    set +u
    source "/opt/ros/$ROS_DISTRO_FOUND/setup.bash"
    [ -f "$HOME/unitree_ros2/cyclonedds_ws/install/setup.bash" ] && source "$HOME/unitree_ros2/cyclonedds_ws/install/setup.bash"
    cd "$REPO_DIR" || exit 1
    colcon build --symlink-install
  ) >>"$LOG_FILE" 2>&1
  if [ -f "$REPO_DIR/install/setup.bash" ]; then
    ok "Workspace built"
  else
    warn "colcon build failed (see $LOG_FILE)"
    manual "Build the workspace by hand; see $LOG_FILE."
  fi
}

# ── 15. verification ────────────────────────────────────────────────────────
result() {
  RESULTS+=("$1|$2")
  case "$1" in
    PASS) ok "$2" ;;
    WARN) warn "$2" ;;
    FAIL) printf '%s fail%s %s\n' "$C_ERR" "$C_OFF" "$2"; FAILED=$((FAILED+1)) ;;
  esac
}

verify() {
  section "15. Verification (nothing is started, the robot is not touched)"
  local m
  for m in faster_whisper sounddevice soundfile openwakeword numpy; do
    python3 -c "import $m" >/dev/null 2>&1 && result PASS "python: $m" || result FAIL "python: $m missing"
  done

  command -v piper >/dev/null 2>&1 && result PASS "piper binary" || result FAIL "piper binary missing"

  local voice="$HOME/.local/share/piper/en_US-lessac-medium.onnx"
  [ -f "$voice" ] && [ -f "$voice.json" ] && result PASS "piper voice model" || result FAIL "piper voice model missing"

  local tts_bin="$HOME/unitree_sdk2_latest/build/bin/g1_piper_tts"
  [ -x "$tts_bin" ] && result PASS "speaker bridge g1_piper_tts" || result FAIL "speaker bridge g1_piper_tts missing"

  if [ -f "/opt/ros/$ROS_DISTRO_FOUND/setup.bash" ]; then
    set +u
    source "/opt/ros/$ROS_DISTRO_FOUND/setup.bash" 2>/dev/null
    [ -f "$HOME/unitree_ros2/cyclonedds_ws/install/setup.bash" ] && source "$HOME/unitree_ros2/cyclonedds_ws/install/setup.bash" 2>/dev/null
    [ -f "$REPO_DIR/install/setup.bash" ] && source "$REPO_DIR/install/setup.bash" 2>/dev/null
    set -u

    local p
    for p in g1_voice bob_llm unitree_go unitree_hg; do
      ros2 pkg prefix "$p" >/dev/null 2>&1 && result PASS "ros package: $p" || result FAIL "ros package: $p not found"
    done

    ros2 launch g1_voice voice_real.launch.py --show-args >/dev/null 2>&1 \
      && result PASS "voice_real.launch.py loads" \
      || result FAIL "voice_real.launch.py does not load"
  else
    result FAIL "ROS 2 not available"
  fi

  if [ -n "$ROBOT_IFACE" ]; then
    result PASS "robot LAN on $ROBOT_IFACE (${ROBOT_IP#* })"
  else
    result WARN "no 192.168.123.x interface — robot link not detected"
  fi

  if command -v ollama >/dev/null 2>&1; then
    case "$(curl -fsS --max-time 3 http://localhost:11434/api/tags 2>/dev/null)" in
      *llama3.2*) result PASS "ollama serving llama3.2" ;;
      *)          result WARN "ollama installed but not serving llama3.2 (start it: ollama serve &)" ;;
    esac
  else
    result WARN "ollama not installed (optional)"
  fi

  # Receive-only: join the mic multicast group for 1 s, then leave.
  if [ -n "$ROBOT_IP" ]; then
    if python3 - "${ROBOT_IP#* }" 2>/dev/null <<'PY'
import socket, struct, sys
local_ip = sys.argv[1].split()[0]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('', 5555))
mreq = struct.pack('4s4s', socket.inet_aton('239.168.123.161'), socket.inet_aton(local_ip))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
s.settimeout(1.0)
try:
    s.recvfrom(2048)
except socket.timeout:
    pass
finally:
    s.setsockopt(socket.IPPROTO_IP, socket.IP_DROP_MEMBERSHIP, mreq)
    s.close()
PY
    then
      result PASS "microphone multicast group joinable"
    else
      result WARN "could not join mic multicast (check the interface / robot link)"
    fi
  fi

  section "Result"
  local total=${#RESULTS[@]} passed=$(( total - FAILED ))
  printf '  %d passed, %d failed, %d warnings\n' "$passed" "$FAILED" "${#WARNINGS[@]}"
  [ "$FAILED" -gt 0 ] && printf '  Fix the failures, then re-run: ./%s --verify\n' "$(basename "$0")"
}

preflight_report() {
  section "Prerequisite report"
  if [ "${#BLOCKERS[@]}" -eq 0 ]; then
    ok "No blockers."
  else
    printf '%sBlockers:%s\n' "$C_ERR" "$C_OFF"
    printf '  - %s\n' "${BLOCKERS[@]}"
  fi
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '%sWarnings:%s\n' "$C_WARN" "$C_OFF"
    printf '  - %s\n' "${WARNINGS[@]}"
  fi
  printf 'Log: %s\n' "$LOG_FILE"
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

print_next_steps() {
  section "Next steps"
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    printf '%sManual steps still required:%s\n' "$C_WARN" "$C_OFF"
    local m
    for m in "${MANUAL[@]}"; do printf '  - %s\n' "$m"; done
  fi
  cat <<EOF

  Nothing was enabled at boot, and nothing was sent to the robot.
  To try the pipeline by hand:

    source /opt/ros/${ROS_DISTRO_FOUND:-foxy}/setup.bash
    source ~/unitree_ros2/cyclonedds_ws/install/setup.bash
    source $REPO_DIR/install/setup.bash
    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
    export CYCLONEDDS_URI=~/cyclonedds_ws/cyclonedds.xml
    ros2 launch g1_voice voice_real.launch.py

  Speaker only, no pipeline (safe, audio only):

    echo "Hello, I am Aletta." | ~/unitree_sdk2_latest/build/bin/g1_piper_tts eth0

  Hold F1 on the remote to talk, release to hear the answer; F3 toggles
  continuous conversation. This pipeline only talks — it never commands motion.

  Auto-start stays off on purpose. Enable it yourself when you trust it:
    sudo cp unitree_converse.service /etc/systemd/system/
    sudo systemctl enable unitree_converse.service

  Full log: $LOG_FILE
EOF
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
  printf '%sunitree_converse — Foxy (Ubuntu 20.04) installer%s\n' "$C_HDR" "$C_OFF"
  printf 'repo: %s\n' "$REPO_DIR"
  printf 'mode: %s%s%s\n' "$MODE" "$([ "$OFFLINE" -eq 1 ] && echo ' (offline)')" "$([ -n "$BUNDLE" ] && echo " bundle=$BUNDLE")"
  : > "$LOG_FILE"

  detect_system
  detect_ros
  detect_network
  preflight_report

  if [ "$MODE" = "check" ]; then
    print_next_steps
    [ "${#BLOCKERS[@]}" -gt 0 ] && exit 1
    exit 0
  fi

  if [ "$MODE" = "verify" ]; then
    verify
    print_next_steps
    [ "$FAILED" -gt 0 ] && exit 2
    exit 0
  fi

  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    printf '\n%sInstallation stopped: fix the blockers above first.%s\n' "$C_ERR" "$C_OFF"
    print_next_steps
    exit 1
  fi

  printf '\nThis installs packages without removing or upgrading any, builds the ROS 2 workspace,\n'
  printf 'and (only with --allow-repo-edits) fixes the LLM node shebang.\n'
  printf 'It will NOT enable auto-start and will NOT send any command to the robot.\n'
  confirm "Continue?" || { printf 'Aborted — nothing was changed.\n'; exit 1; }

  step_apt
  step_python
  step_piper
  step_whisper_model
  step_ollama
  step_submodule
  step_unitree_ros2
  step_cyclonedds_config
  step_tts_bridge
  step_build_workspace

  verify
  print_next_steps
  [ "$FAILED" -gt 0 ] && exit 2
  exit 0
}

main
