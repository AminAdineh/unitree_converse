// g1_piper_tts.cpp — speak text from stdin through the G1 speaker.
//
// The pipeline (tts_node.py) runs this binary as:
//     g1_piper_tts eth0  <  "text to speak"
//
// It synthesises the text with Piper, converts the result to the only format the
// Unitree AudioClient accepts (16 kHz, mono, 16-bit PCM) and plays it with
// PlayStream(). The robot's speaker is driven by the RockChip MCU at
// 192.168.123.161, not by the Jetson's ALSA/PulseAudio, so this binary must run
// on the Jetson with the Ethernet link to the robot up.
//
// Build (see tools/g1_piper_tts/README.md):
//     cp tools/g1_piper_tts/g1_piper_tts.cpp ~/unitree_sdk2_latest/example/g1/audio/
//     printf '\nadd_executable(g1_piper_tts audio/g1_piper_tts.cpp)\n'
//       'target_link_libraries(g1_piper_tts unitree_sdk2)\n' >> ~/unitree_sdk2_latest/example/g1/CMakeLists.txt
//     cd ~/unitree_sdk2_latest/build && cmake .. && make g1_piper_tts -j$(nproc)
//
// It only plays audio. It never sends a motion or low-level command.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

#include <unitree/common/time/time_tool.hpp>
#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/g1/audio/g1_audio_client.hpp>

namespace {

constexpr int kSampleRate = 16000;
constexpr int kBytesPerSample = 2;  // 16-bit mono
constexpr const char *kStreamName = "piper_tts";

// Reads a RIFF/WAVE file and returns its PCM payload. Reports the format so the
// caller can refuse anything the AudioClient would reject.
std::vector<uint8_t> read_wav(const std::string &path, int *rate, int *channels, int *bits) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    return {};
  }
  std::vector<uint8_t> raw((std::istreambuf_iterator<char>(in)),
                           std::istreambuf_iterator<char>());
  if (raw.size() < 12 || std::memcmp(raw.data(), "RIFF", 4) != 0 ||
      std::memcmp(raw.data() + 8, "WAVE", 4) != 0) {
    return {};
  }

  bool have_format = false;
  size_t pos = 12;
  while (pos + 8 <= raw.size()) {
    const char *id = reinterpret_cast<const char *>(raw.data() + pos);
    uint32_t size = 0;
    std::memcpy(&size, raw.data() + pos + 4, sizeof(size));
    const size_t body = pos + 8;
    if (body + size > raw.size()) {
      break;
    }
    if (std::memcmp(id, "fmt ", 4) == 0 && size >= 16) {
      uint16_t ch = 0;
      uint16_t bps = 0;
      uint32_t sr = 0;
      std::memcpy(&ch, raw.data() + body + 2, sizeof(ch));
      std::memcpy(&sr, raw.data() + body + 4, sizeof(sr));
      std::memcpy(&bps, raw.data() + body + 14, sizeof(bps));
      *channels = ch;
      *rate = static_cast<int>(sr);
      *bits = bps;
      have_format = true;
    } else if (std::memcmp(id, "data", 4) == 0 && have_format) {
      return std::vector<uint8_t>(raw.begin() + body, raw.begin() + body + size);
    }
    pos = body + size + (size & 1);
  }
  return {};
}

// Runs a shell command with `input` on its stdin; true when it exits 0.
bool run_with_stdin(const std::string &command, const std::string &input) {
  FILE *pipe = popen(command.c_str(), "w");
  if (pipe == nullptr) {
    return false;
  }
  if (!input.empty()) {
    std::fwrite(input.data(), 1, input.size(), pipe);
  }
  return pclose(pipe) == 0;
}

bool run(const std::string &command) { return std::system(command.c_str()) == 0; }

std::string trim(const std::string &text) {
  const size_t first = text.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) {
    return "";
  }
  const size_t last = text.find_last_not_of(" \t\r\n");
  return text.substr(first, last - first + 1);
}

}  // namespace

int main(int argc, char const *argv[]) {
  if (argc < 2) {
    std::cerr << "Usage: g1_piper_tts [NetWorkInterface(eth0)]  (text on stdin)" << std::endl;
    return 1;
  }
  const std::string interface = argv[1];

  std::ostringstream buffer;
  buffer << std::cin.rdbuf();
  const std::string text = trim(buffer.str());
  if (text.empty()) {
    std::cerr << "g1_piper_tts: no text on stdin" << std::endl;
    return 1;
  }

  const char *voice_env = std::getenv("PIPER_VOICE");
  const std::string voice =
      voice_env != nullptr && voice_env[0] != '\0'
          ? voice_env
          : "/home/unitree/.local/share/piper/en_US-lessac-medium.onnx";

  // Piper reads the text on stdin and writes a 22.05 kHz WAV.
  const std::string synth =
      "piper --model \"" + voice + "\" --output_file /tmp/tts_raw.wav 2>/dev/null";
  if (!run_with_stdin(synth, text + "\n")) {
    std::cerr << "g1_piper_tts: piper failed (is `piper` on PATH and the voice model at "
              << voice << "?)" << std::endl;
    return 1;
  }

  // PlayStream only accepts 16 kHz mono 16-bit PCM.
  if (!run("sox /tmp/tts_raw.wav -r 16000 -c 1 -b 16 /tmp/tts_16k.wav 2>/dev/null")) {
    std::cerr << "g1_piper_tts: sox conversion failed" << std::endl;
    return 1;
  }

  int rate = 0;
  int channels = 0;
  int bits = 0;
  const std::vector<uint8_t> pcm = read_wav("/tmp/tts_16k.wav", &rate, &channels, &bits);
  if (pcm.empty() || rate != kSampleRate || channels != 1 || bits != 16) {
    std::cerr << "g1_piper_tts: expected 16 kHz mono 16-bit audio, got " << rate << " Hz / "
              << channels << " ch / " << bits << " bit" << std::endl;
    return 1;
  }

  unitree::robot::ChannelFactory::Instance()->Init(0, interface);
  unitree::robot::g1::AudioClient client;
  client.Init();
  client.SetTimeout(10.0f);

  const std::string stream_id =
      std::to_string(unitree::common::GetCurrentTimeMillisecond());
  if (client.PlayStream(kStreamName, stream_id, pcm) != 0) {
    std::cerr << "g1_piper_tts: PlayStream failed (is the robot link up on " << interface
              << "?)" << std::endl;
    return 1;
  }

  const int play_seconds = static_cast<int>(pcm.size() / (kSampleRate * kBytesPerSample)) + 1;
  unitree::common::Sleep(play_seconds);
  client.PlayStop(kStreamName);
  return 0;
}
