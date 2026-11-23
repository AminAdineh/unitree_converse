#!/usr/bin/env bash
# install_jetson.sh — guided installer and verifier for unitree_converse
# on a Unitree G1 (NVIDIA Jetson Orin, Ubuntu 22.04).
#
# It never moves the robot, never enables systemd auto-start and never edits
# the repository's source. Everything it cannot do safely is reported as a
# manual step at the end.
#
# Usage:
#   ./install_jetson.sh            # check -> ask -> install -> verify
#   ./install_jetson.sh --check    # prerequisite report only, changes nothing
#   ./install_jetson.sh --install  # check + install (asks first)
#   ./install_jetson.sh --verify   # verification only, changes nothing
#   ./install_jetson.sh --yes      # do not ask for confirmation
#
# Exit codes: 0 ok, 1 blocked by a prerequisite, 2 verification failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/unitree_converse_install_$(date +%Y%m%d_%H%M%S).log"

MODE="all"
ASSUME_YES=0

usage() {
  cat <<'EOF'
unitree_converse — guided installer and verifier for a Unitree G1 Jetson.

It never moves the robot, never enables systemd auto-start and never edits
the repository's source. Anything it cannot do safely is reported as a
manual step at the end.

Usage:
  ./install_jetson.sh            check -> ask -> install -> verify
  ./install_jetson.sh --check    prerequisite report only, changes nothing
  ./install_jetson.sh --install  check + install (asks first)
  ./install_jetson.sh --verify   verification only, changes nothing
  ./install_jetson.sh --yes      do not ask for confirmation
  ./install_jetson.sh --help     this text

Exit codes: 0 ok, 1 blocked by a prerequisite, 2 verification failed.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check)   MODE="check" ;;
    --install) MODE="install" ;;
    --verify)  MODE="verify" ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $arg (use --help)"; exit 1 ;;
  esac
done

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

BLOCKERS=(); WARNINGS=(); MANUAL=(); RESULTS=()

run() { "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"; }

# ── environment facts ───────────────────────────────────────────────────────
SUDO=""
[ "$EUID" -ne 0 ] && SUDO="sudo"

OS_ID=""; OS_VER=""; ARCH="$(uname -m)"; JETSON_MODEL="unknown"
ROS_DISTRO_FOUND=""; ROBOT_IFACE=""; ROBOT_IP=""
HAVE_INTERNET=0

detect_system() {
  section "1. System"
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
  fi
  local os_name
  os_name="$(printf '%s' "${OS_ID:-unknown}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') ${OS_VER:-}"
  if [ "$OS_ID" = "ubuntu" ] && [ "$OS_VER" = "22.04" ]; then
    ok "Ubuntu 22.04 ($ARCH)"
  elif [ -n "$OS_VER" ]; then
    warn "${os_name}found; this installer targets Ubuntu 22.04 (the upstream docs assume 20.04 / ROS 2 Foxy)."
  else
    warn "Could not read /etc/os-release."
  fi

  if [ -r /proc/device-tree/model ]; then
    JETSON_MODEL="$(tr -d '\0' < /proc/device-tree/model)"
    ok "Board: $JETSON_MODEL"
  else
    warn "No Jetson device tree found — this does not look like a Jetson."
  fi

  if [ "$ARCH" = "aarch64" ]; then
    ok "Architecture: aarch64"
  else
    warn "Architecture is $ARCH, not aarch64: the aarch64 Piper binary will not run."
  fi

  local free_mb
  free_mb="$(df -Pm "$HOME" | awk 'NR==2 {print $4}')"
  if [ "${free_mb:-0}" -lt 6000 ]; then
    warn "Only ${free_mb} MB free in $HOME; models and builds need ~6 GB."
  else
    ok "Free space in \$HOME: ${free_mb} MB"
  fi

  if [ "$(id -un)" = "unitree" ]; then
    ok "User: unitree"
  else
    warn "Running as '$(id -un)'. The project config expects /home/unitree paths (voice model, g1_piper_tts)."
  fi
}

detect_ros() {
  section "2. ROS 2"
  local d
  for d in humble foxy jazzy iron; do
    if [ -d "/opt/ros/$d" ]; then ROS_DISTRO_FOUND="$d"; break; fi
  done

  if [ -z "$ROS_DISTRO_FOUND" ]; then
    fail "No ROS 2 installation found in /opt/ros. Install ROS 2 Humble first (see the manual steps at the end)."
    return
  fi
  ok "ROS 2 $ROS_DISTRO_FOUND found at /opt/ros/$ROS_DISTRO_FOUND"

  if [ "$ROS_DISTRO_FOUND" != "foxy" ]; then
    warn "The project is documented for Foxy on the Jetson; you have $ROS_DISTRO_FOUND. The nodes are plain rclpy and normally work, but the robot's own unitree_ros2 packages must be built for $ROS_DISTRO_FOUND."
  fi

  if [ -f "/opt/ros/$ROS_DISTRO_FOUND/setup.bash" ]; then
    ok "setup.bash present"
  else
    fail "/opt/ros/$ROS_DISTRO_FOUND/setup.bash is missing — the ROS 2 install looks incomplete."
  fi

  # shellcheck disable=SC1090
  set +u; source "/opt/ros/$ROS_DISTRO_FOUND/setup.bash" 2>/dev/null; set -u
  if command -v colcon >/dev/null 2>&1; then ok "colcon available"; else warn "colcon not installed (python3-colcon-common-extensions)."; fi

  if ros2 pkg prefix rmw_cyclonedds_cpp >/dev/null 2>&1; then
    ok "CycloneDDS RMW available"
  else
    warn "rmw_cyclonedds_cpp not found (ros-$ROS_DISTRO_FOUND-rmw-cyclonedds-cpp)."
  fi
}

probe_internet() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 6 -o /dev/null https://github.com 2>/dev/null && return 0
    curl -fsS --max-time 6 -o /dev/null https://pypi.org 2>/dev/null && return 0
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
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
    return $?
  fi
  return 2
}

detect_network() {
  section "3. Network"
  local net
  probe_internet; net=$?
  if [ "$net" -eq 0 ]; then
    HAVE_INTERNET=1
    ok "Internet reachable (downloads will work)"
  elif [ "$net" -eq 2 ]; then
    warn "Could not check internet access (no curl or python3). Downloads may still work."
  else
    warn "No internet access detected. Installation needs to download packages and models; an offline install is NOT supported by this script."
  fi

  # The robot link carries 192.168.123.x (Jetson .164, RockChip .161).
  ROBOT_IP="$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.123\./ {sub(/\/.*/,"",$4); print $2, $4; exit}')"
  if [ -n "$ROBOT_IP" ]; then
    ROBOT_IFACE="${ROBOT_IP%% *}"
    ok "Robot LAN: ${ROBOT_IFACE} has ${ROBOT_IP#* }"
    if [ "$ROBOT_IFACE" != "eth0" ]; then
      warn "Robot link is on '$ROBOT_IFACE', not eth0. The TTS node calls g1_piper_tts with a hardcoded 'eth0' and the project docs assume eth0 — rename or bridge the interface before running the pipeline."
    fi
  else
    warn "No interface with a 192.168.123.x address. Connect the Ethernet cable to the robot (or configure the static IP) before running the pipeline."
  fi

  if [ -n "$ROBOT_IP" ]; then
    if ip -4 -o addr show 2>/dev/null | grep -q "192\.168\.123\.164/"; then
      ok "Jetson address 192.168.123.164 present (matches stt_node udp_local_ip)"
    else
      warn "Jetson does not have 192.168.123.164, which voice_params_real.yaml expects for the microphone multicast."
    fi
  fi
}

detect_components() {
  section "4. Components"
  local missing=0

  command -v git >/dev/null 2>&1 && ok "git" || { warn "git missing"; missing=1; }
  command -v curl >/dev/null 2>&1 && ok "curl" || { warn "curl missing"; missing=1; }
  command -v sox >/dev/null 2>&1 && ok "sox" || { warn "sox missing"; missing=1; }
  command -v piper >/dev/null 2>&1 && ok "piper binary" || { warn "piper binary missing"; missing=1; }
  command -v ollama >/dev/null 2>&1 && ok "ollama" || { warn "ollama missing"; missing=1; }

  local py_missing=""
  for m in faster_whisper sounddevice soundfile openwakeword numpy; do
    python3 -c "import $m" >/dev/null 2>&1 || py_missing="$py_missing $m"
  done
  if [ -z "$py_missing" ]; then ok "Python modules present"; else warn "Python modules missing:$py_missing"; missing=1; fi

  local voice="$HOME/.local/share/piper/en_US-lessac-medium.onnx"
  [ -f "$voice" ] && ok "Piper voice model" || { warn "Piper voice model missing ($voice)"; missing=1; }

  local tts_bin="$HOME/unitree_sdk2_latest/build/bin/g1_piper_tts"
  if [ -x "$tts_bin" ]; then
    ok "Speaker binary g1_piper_tts"
  else
    warn "Speaker binary missing: $tts_bin"
    MANUAL+=("Build g1_piper_tts from unitree_sdk2 (example/g1/audio) — this script cannot supply that C++ source.")
    missing=1
  fi

  if [ -f "$HOME/cyclonedds_ws/cyclonedds.xml" ]; then
    ok "cyclonedds.xml present"
  else
    warn "~/cyclonedds_ws/cyclonedds.xml missing (DDS interface config)"
  fi

  [ "$missing" -eq 0 ] && info "All components present." || info "Missing pieces are installed in the next step where possible."
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

# ── installation steps ──────────────────────────────────────────────────────
pip_install() {
  if python3 -m pip install --user "$@" >>"$LOG_FILE" 2>&1; then return 0; fi
  # Ubuntu 22.04 marks the system Python as externally managed (PEP 668).
  if python3 -m pip install --user --break-system-packages "$@" >>"$LOG_FILE" 2>&1; then return 0; fi
  return 1
}

network_hint() {
  if [ "$HAVE_INTERNET" -eq 0 ]; then
    note "This looks like a network problem: no internet access was detected."
  fi
  note "See $LOG_FILE for details."
}

step_apt() {
  section "5. System packages"
  info "Installing sox, portaudio, pip, colcon, CycloneDDS RMW"
  if ! $SUDO apt-get update >>"$LOG_FILE" 2>&1; then
    warn "apt-get update failed"; network_hint; return 1
  fi
  # build-essential/cmake: bob_llm is an ament_cmake package, colcon needs a compiler.
  local pkgs=(sox portaudio19-dev libsndfile1 python3-pip python3-yaml
              python3-colcon-common-extensions build-essential cmake)
  if $SUDO apt-get install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1; then
    ok "System packages installed"
  else
    warn "Some system packages failed to install"; network_hint; return 1
  fi

  # CycloneDDS and ament_cmake_python are ROS packages; tolerate a missing one.
  if [ -n "$ROS_DISTRO_FOUND" ]; then
    if $SUDO apt-get install -y "ros-${ROS_DISTRO_FOUND}-rmw-cyclonedds-cpp" \
                                 "ros-${ROS_DISTRO_FOUND}-ament-cmake-python" >>"$LOG_FILE" 2>&1; then
      ok "ROS packages (CycloneDDS RMW, ament_cmake_python) installed"
    else
      warn "Could not install ros-${ROS_DISTRO_FOUND}-rmw-cyclonedds-cpp / -ament-cmake-python"
      MANUAL+=("Install ros-${ROS_DISTRO_FOUND}-rmw-cyclonedds-cpp and ros-${ROS_DISTRO_FOUND}-ament-cmake-python.")
    fi
  fi
}

step_python() {
  section "6. Python dependencies"
  # requests is imported by the bob_llm node.
  if pip_install faster-whisper sounddevice soundfile tqdm filelock openwakeword numpy requests; then
    ok "Python dependencies installed"
  else
    warn "pip install failed"; network_hint; return 1
  fi
}

step_piper() {
  section "7. Piper (text to speech)"
  if command -v piper >/dev/null 2>&1; then
    ok "piper already installed"
  else
    if [ "$ARCH" != "aarch64" ]; then
      warn "Skipping Piper binary: needs aarch64"
      return 1
    fi
    local tmp; tmp="$(mktemp -d)"
    info "Downloading Piper aarch64 binary"
    if ! curl -fsSL -o "$tmp/piper.tar.gz" \
        https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_aarch64.tar.gz >>"$LOG_FILE" 2>&1; then
      warn "Piper download failed"; network_hint; rm -rf "$tmp"; return 1
    fi
    if tar -xzf "$tmp/piper.tar.gz" -C "$tmp" >>"$LOG_FILE" 2>&1 && $SUDO cp "$tmp/piper/piper" /usr/local/bin/piper; then
      $SUDO chmod +x /usr/local/bin/piper
      ok "Piper installed at /usr/local/bin/piper"
    else
      warn "Piper install failed"; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
  fi

  local dir="$HOME/.local/share/piper"
  mkdir -p "$dir"
  local base="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
  for f in "en_US-lessac-medium.onnx" "en_US-lessac-medium.onnx.json"; do
    if [ -f "$dir/$f" ]; then
      ok "Voice model $f present"
    else
      info "Downloading $f"
      if curl -fsSL -o "$dir/$f" "$base${f#en_US-lessac-medium.onnx}" >>"$LOG_FILE" 2>&1; then
        ok "Voice model $f downloaded"
      else
        warn "Voice model download failed ($f)"; network_hint
      fi
    fi
  done
}

step_whisper_model() {
  section "8. Speech recognition model"
  info "Pre-downloading faster-whisper 'base' (CPU int8)"
  if python3 -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8')" >>"$LOG_FILE" 2>&1; then
    ok "faster-whisper base model cached"
  else
    warn "faster-whisper model download failed"; network_hint; return 1
  fi
}

step_ollama() {
  section "9. Local language model (Ollama + llama3.2)"
  if ! command -v ollama >/dev/null 2>&1; then
    if ! command -v curl >/dev/null 2>&1; then
      warn "curl is required to install Ollama"; network_hint; return 1
    fi
    info "Installing Ollama"
    if ! curl -fsSL https://ollama.com/install.sh | sh >>"$LOG_FILE" 2>&1; then
      warn "Ollama install failed"; network_hint; return 1
    fi
    ok "Ollama installed"
  else
    ok "Ollama already installed"
  fi

  # The upstream installer enables a systemd service. This install-and-test
  # flow must not create auto-start, so it is disabled but left running now.
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ollama.service >/dev/null 2>&1; then
    if systemctl is-enabled ollama.service >/dev/null 2>&1; then
      $SUDO systemctl disable ollama.service >>"$LOG_FILE" 2>&1 || true
      info "Disabled ollama auto-start (enable later with: sudo systemctl enable ollama)"
    fi
    $SUDO systemctl start ollama.service >>"$LOG_FILE" 2>&1 || true
  fi

  if ! curl -fsS --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    info "Starting Ollama in the background"
    nohup ollama serve >>"$LOG_FILE" 2>&1 &
    for _ in $(seq 1 20); do
      curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1 && break
      sleep 1
    done
  fi

  if curl -fsS --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    ok "Ollama responding on :11434"
  else
    warn "Ollama is not responding on :11434"; network_hint; return 1
  fi

  info "Pulling llama3.2 (about 2 GB)"
  if ollama pull llama3.2 >>"$LOG_FILE" 2>&1; then
    ok "llama3.2 available"
  else
    warn "ollama pull llama3.2 failed"; network_hint; return 1
  fi
}

# launch_ros runs the node file directly, so it needs a shebang and the
# executable bit. bob_llm ships llm_node.py without either, which otherwise
# fails at launch with "Exec format error".
ensure_bob_llm_scripts() {
  local node="$REPO_DIR/src/bob_llm/bob_llm/llm_node.py"
  if [ ! -f "$node" ]; then
    warn "src/bob_llm/bob_llm/llm_node.py not found"
    return 1
  fi
  local fixed=0 first
  first="$(head -1 "$node" 2>/dev/null)"
  case "$first" in
    '#!'*) : ;;
    *)
      local tmp; tmp="$(mktemp)"
      { echo '#!/usr/bin/env python3'; cat "$node"; } > "$tmp" && cat "$tmp" > "$node"
      rm -f "$tmp"
      fixed=1
      ;;
  esac
  chmod +x "$REPO_DIR"/src/bob_llm/bob_llm/*.py 2>/dev/null
  if [ "$fixed" -eq 1 ]; then
    ok "Added the missing shebang to the LLM node and made it executable"
  else
    ok "LLM node script is executable"
  fi
}

step_submodule() {
  section "10. LLM ROS package (bob_llm submodule)"
  if [ -n "$(ls -A "$REPO_DIR/src/bob_llm" 2>/dev/null)" ]; then
    ok "src/bob_llm already populated"
  else
    info "Fetching submodule"
    if git -C "$REPO_DIR" submodule update --init --recursive >>"$LOG_FILE" 2>&1; then
      ok "Submodule initialised"
    else
      info "Submodule URL needs SSH keys; falling back to the public HTTPS fork"
      # Clone next to the target first, so a failed download never removes
      # the existing directory.
      local target="$REPO_DIR/src/bob_llm" tmpc="$REPO_DIR/src/.bob_llm_clone"
      rm -rf "$tmpc"
      if git clone --depth 1 https://github.com/AkhileshSingh01/bob_llm.git "$tmpc" >>"$LOG_FILE" 2>&1; then
        rm -rf "$target"
        mv "$tmpc" "$target"
        ok "bob_llm cloned from public fork"
      else
        rm -rf "$tmpc"
        warn "Could not fetch bob_llm"; network_hint
        MANUAL+=("Clone bob_llm into src/bob_llm manually.")
        return 1
      fi
    fi
  fi
  ensure_bob_llm_scripts
}

step_unitree_ros2() {
  section "11. Unitree robot messages"
  if ros2 pkg prefix unitree_go >/dev/null 2>&1 && ros2 pkg prefix unitree_hg >/dev/null 2>&1; then
    ok "unitree_go / unitree_hg already available"
    return 0
  fi
  local dir="$HOME/unitree_ros2"
  if [ ! -d "$dir" ]; then
    info "Cloning unitree_ros2"
    if ! git clone --depth 1 https://github.com/unitreerobotics/unitree_ros2.git "$dir" >>"$LOG_FILE" 2>&1; then
      warn "unitree_ros2 clone failed"; network_hint
      MANUAL+=("Clone https://github.com/unitreerobotics/unitree_ros2 and build unitree_go, unitree_api, unitree_hg.")
      return 1
    fi
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
    warn "Unitree message build failed"
    MANUAL+=("Build unitree_ros2/cyclonedds_ws manually; see $LOG_FILE.")
    return 1
  fi
}

step_cyclonedds_config() {
  section "12. DDS interface config"
  local dir="$HOME/cyclonedds_ws" cfg="$HOME/cyclonedds_ws/cyclonedds.xml"
  if [ -f "$cfg" ]; then
    ok "cyclonedds.xml already present"
    return 0
  fi
  local iface="${ROBOT_IFACE:-eth0}"
  mkdir -p "$dir"
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
  [ -z "$ROBOT_IFACE" ] && warn "No robot interface detected; cyclonedds.xml defaults to eth0 — adjust it after connecting the cable."
}

step_build_workspace() {
  section "13. ROS 2 workspace build"
  info "colcon build --symlink-install in $REPO_DIR"
  (
    set +u
    source "/opt/ros/$ROS_DISTRO_FOUND/setup.bash"
    [ -f "$HOME/cyclonedds_ws/install/setup.bash" ] && source "$HOME/cyclonedds_ws/install/setup.bash"
    [ -f "$HOME/unitree_ros2/cyclonedds_ws/install/setup.bash" ] && source "$HOME/unitree_ros2/cyclonedds_ws/install/setup.bash"
    cd "$REPO_DIR" || exit 1
    colcon build --symlink-install
  ) >>"$LOG_FILE" 2>&1
  if [ -f "$REPO_DIR/install/setup.bash" ]; then
    ok "Workspace built"
  else
    warn "Workspace build failed"
    note "Common cause: bob_llm needs a Foxy-compatible CMakeLists (setup.sh patches it) or a missing dependency."
    MANUAL+=("Review the colcon build log in $LOG_FILE.")
    return 1
  fi
}

# ── verification ────────────────────────────────────────────────────────────
result() { # result <PASS|WARN|FAIL> <text>
  RESULTS+=("$1|$2")
  case "$1" in
    PASS) ok "$2" ;;
    WARN) warn "$2" ;;
    FAIL) printf '%s fail%s %s\n' "$C_ERR" "$C_OFF" "$2"; FAILED=$((FAILED+1)) ;;
  esac
}
FAILED=0

verify() {
  section "14. Verification (nothing is started, the robot is not touched)"

  for m in faster_whisper sounddevice soundfile openwakeword numpy; do
    if python3 -c "import $m" >/dev/null 2>&1; then result PASS "python: $m"; else result FAIL "python: $m missing"; fi
  done

  if command -v piper >/dev/null 2>&1; then result PASS "piper binary"; else result FAIL "piper binary missing"; fi

  local voice="$HOME/.local/share/piper/en_US-lessac-medium.onnx"
  [ -f "$voice" ] && [ -f "$voice.json" ] && result PASS "piper voice model" || result FAIL "piper voice model missing"

  local tags
  tags="$(curl -fsS --max-time 3 http://localhost:11434/api/tags 2>/dev/null)"
  case "$tags" in
    *llama3.2*) result PASS "ollama serving llama3.2" ;;
    *)          result FAIL "ollama not serving llama3.2" ;;
  esac

  if [ -f "/opt/ros/$ROS_DISTRO_FOUND/setup.bash" ]; then
    set +u; source "/opt/ros/$ROS_DISTRO_FOUND/setup.bash" 2>/dev/null
    [ -f "$HOME/unitree_ros2/cyclonedds_ws/install/setup.bash" ] && source "$HOME/unitree_ros2/cyclonedds_ws/install/setup.bash" 2>/dev/null
    [ -f "$REPO_DIR/install/setup.bash" ] && source "$REPO_DIR/install/setup.bash" 2>/dev/null
    set -u

    for p in g1_voice bob_llm unitree_go unitree_hg; do
      if ros2 pkg prefix "$p" >/dev/null 2>&1; then result PASS "ros package: $p"; else result FAIL "ros package: $p not found"; fi
    done

    local bob_prefix llm_bin llm_first
    bob_prefix="$(ros2 pkg prefix bob_llm 2>/dev/null)"
    llm_bin="$bob_prefix/lib/bob_llm/llm_node.py"
    llm_first="$(head -1 "$llm_bin" 2>/dev/null)"
    case "$llm_first" in
      '#!'*)
        if [ -x "$llm_bin" ]; then
          result PASS "llm node runnable"
        else
          result FAIL "llm node is not executable (re-run --install)"
        fi
        ;;
      *)
        if [ -f "$llm_bin" ]; then
          result FAIL "llm node has no shebang (re-run --install)"
        else
          result FAIL "bob_llm does not install llm_node.py"
        fi
        ;;
    esac

    # Loads the real launch file (parameters, nodes) without starting anything.
    if ros2 launch g1_voice voice_real.launch.py --show-args >/dev/null 2>&1; then
      result PASS "voice_real.launch.py loads"
    else
      result FAIL "voice_real.launch.py does not load"
    fi
  else
    result FAIL "ROS 2 not available"
  fi

  if [ -n "$ROBOT_IFACE" ]; then
    result PASS "robot LAN on $ROBOT_IFACE (${ROBOT_IP#* })"
  else
    result WARN "no 192.168.123.x interface — robot link not detected"
  fi

  local tts_bin="$HOME/unitree_sdk2_latest/build/bin/g1_piper_tts"
  if [ -x "$tts_bin" ]; then result PASS "speaker binary g1_piper_tts"; else result WARN "speaker binary g1_piper_tts missing"; fi

  # Microphone multicast is receive-only: join the group, listen 1 s, leave.
  if [ -n "$ROBOT_IP" ]; then
    if python3 - "${ROBOT_IP#* }" 2>/dev/null <<'PY'
import socket, struct, sys, time
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
  local total=${#RESULTS[@]} passed=$(( ${#RESULTS[@]} - FAILED ))
  printf '  %d passed, %d failed, %d warnings\n' "$passed" "$FAILED" "${#WARNINGS[@]}"
  [ "$FAILED" -gt 0 ] && printf '  Fix the failed checks, then re-run: %s --verify\n' "./$(basename "$0")"
}

print_next_steps() {
  section "Next steps"
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    printf '%sManual steps still required:%s\n' "$C_WARN" "$C_OFF"
    printf '  - %s\n' "${MANUAL[@]}"
  fi
  cat <<EOF

  Nothing was enabled at boot. To try the pipeline by hand:

    source /opt/ros/${ROS_DISTRO_FOUND:-humble}/setup.bash
    source ~/unitree_ros2/cyclonedds_ws/install/setup.bash
    source $REPO_DIR/install/setup.bash
    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
    export CYCLONEDDS_URI=~/cyclonedds_ws/cyclonedds.xml
    ros2 launch g1_voice voice_real.launch.py

  Hold F1 on the remote to talk, release to hear the answer; F3 toggles
  continuous conversation. This pipeline only talks — it never commands motion.

  Enable auto-start later (optional):
    sudo cp unitree_converse.service /etc/systemd/system/
    sudo systemctl enable ollama.service unitree_converse.service

  Full log: $LOG_FILE
EOF
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
  printf '%sunitree_converse — Jetson installer%s\n' "$C_HDR" "$C_OFF"
  printf 'repo: %s\n' "$REPO_DIR"
  : > "$LOG_FILE"

  detect_system
  detect_ros
  detect_network
  detect_components
  preflight_report

  if [ "$MODE" = "check" ]; then
    print_next_steps
    [ "${#BLOCKERS[@]}" -gt 0 ] && exit 1
    exit 0
  fi

  if [ "$MODE" = "verify" ]; then
    [ "${#BLOCKERS[@]}" -gt 0 ] && printf '\n%sNote:%s blockers above may cause verification failures.\n' "$C_WARN" "$C_OFF"
    verify
    [ "$FAILED" -gt 0 ] && exit 2
    exit 0
  fi

  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    printf '\n%sInstallation stopped: fix the blockers above first.%s\n' "$C_ERR" "$C_OFF"
    print_next_steps
    exit 1
  fi

  if [ "$MODE" = "all" ]; then
    printf '\nThis will install packages, download ~3 GB of models, and build the ROS 2 workspace.\n'
    printf 'It will NOT enable auto-start and will NOT send any command to the robot.\n'
    confirm "Continue?" || { printf 'Aborted — nothing was changed.\n'; exit 1; }
  elif [ "$MODE" = "install" ] && ! confirm "Proceed with installation?"; then
    printf 'Aborted — nothing was changed.\n'; exit 1
  fi

  step_apt
  step_python
  step_piper
  step_whisper_model
  step_ollama
  step_submodule
  step_unitree_ros2
  step_cyclonedds_config
  step_build_workspace

  verify
  print_next_steps

  if [ "$FAILED" -gt 0 ]; then
    exit 2
  fi
  exit 0
}

main
