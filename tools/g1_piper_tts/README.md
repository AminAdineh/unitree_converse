# g1_piper_tts — Piper speech on the G1 speaker

`tts_node.py` speaks through this small C++ binary:

```
tts_node → g1_piper_tts eth0 < text
              ├── piper → /tmp/tts_raw.wav   (22050 Hz)
              ├── sox   → /tmp/tts_16k.wav   (16000 Hz mono 16-bit)
              └── AudioClient::PlayStream() → RockChip MCU → speaker
```

The G1 speaker is driven by the RockChip MCU at `192.168.123.161` over the robot
Ethernet link, not by the Jetson's ALSA/PulseAudio, and `PlayStream()` only accepts
16 kHz mono 16-bit PCM. That conversion is the whole job of this binary.

It only plays audio. It never sends a motion or low-level command.

## Prerequisites

On the Jetson:

- `unitree_sdk2` cloned to `~/unitree_sdk2_latest`
- `piper` on `PATH` (aarch64 build) with a voice model, by default
  `~/.local/share/piper/en_US-lessac-medium.onnx` (override with `PIPER_VOICE`)
- `sox` (`sudo apt-get install -y sox`)
- the robot Ethernet link up on the interface you pass (`eth0`)

## Build

```bash
cd ~/unitree_sdk2_latest
cp ~/unitree_converse/tools/g1_piper_tts/g1_piper_tts.cpp example/g1/audio/
printf '\nadd_executable(g1_piper_tts audio/g1_piper_tts.cpp)\ntarget_link_libraries(g1_piper_tts unitree_sdk2)\n' >> example/g1/CMakeLists.txt
cd build && cmake .. && make g1_piper_tts -j$(nproc)
```

The binary lands at `~/unitree_sdk2_latest/build/bin/g1_piper_tts`, which is the
path `tts_node.py` expects.

## Test it on its own

```bash
echo "Hello, I am Aletta." | ~/unitree_sdk2_latest/build/bin/g1_piper_tts eth0
```

Exit code 0 means the PCM was handed to the robot and playback finished. A non-zero
exit prints the reason on stderr: `piper failed` (missing binary or voice model),
`sox conversion failed`, `expected 16 kHz mono 16-bit audio`, or `PlayStream failed`
(usually the robot link is down or the interface name is wrong).

If the command succeeds but nothing is heard, check the robot's own volume with the
`AudioClient::GetVolume` / `SetVolume` example in `unitree_sdk2`, and remember the
speaker only plays while the robot is powered on and the link is up.
