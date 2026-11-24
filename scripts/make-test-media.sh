#!/bin/bash
# Generates the media used by the end-to-end tests: synthetic speech with known pauses,
# mixed with different amounts of background noise, wrapped in small video files.
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/Tests/Fixtures/media}"
mkdir -p "$OUT"
cd "$OUT"

# Speech with pauses of known length ([[slnc ms]]).
say -o speech_raw.aiff "[[slnc 1200]] Hello and welcome back to the channel. [[slnc 900]] Today we are going to look at something a little bit different. [[slnc 2500]] First, let me show you how this works, and then we will go through it step by step. [[slnc 700]] So, [[slnc 300]] the first thing you need is a quiet room. [[slnc 1800]] Then press record, and start talking. [[slnc 4000]] If you make a mistake, just pause, [[slnc 1500]] and say the sentence again. [[slnc 600]] That is really all there is to it. [[slnc 3000]] Thanks for watching, and see you next time. [[slnc 2000]]"

# Normalise speech to about -3 dBFS peak, stereo 48 kHz.
ffmpeg -v error -y -i speech_raw.aiff -af "loudnorm=I=-18:TP=-3,aresample=48000" -ac 2 -c:a pcm_s16le speech_clean.wav
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 speech_clean.wav)

mix() { # name noise_amplitude
  ffmpeg -v error -y -i speech_clean.wav -f lavfi -i "anoisesrc=d=${DUR}:c=pink:r=48000:a=$2" \
    -filter_complex "[0:a][1:a]amix=inputs=2:normalize=0:duration=first[a]" -map "[a]" -ac 2 -c:a pcm_s16le "$1.wav"
}
mix speech_studio 0.002     # treated room / good mic
mix speech_room   0.012     # normal untreated room
mix speech_noisy  0.06      # fan / street noise

video() { # name fps_expr
  ffmpeg -v error -y -f lavfi -i "testsrc2=size=640x360:rate=$2:duration=${DUR}" -i "$1.wav" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 160k -shortest "$3.mov"
}
video speech_studio 30 talk_studio
video speech_room   30 talk_room
video speech_noisy  30 talk_noisy
video speech_room   24000/1001 talk_room_2398

# Continuous music-like bed (no silence at all) and a quiet ambience clip.
ffmpeg -v error -y -f lavfi -i "sine=f=220:d=${DUR}:r=48000" -f lavfi -i "sine=f=330:d=${DUR}:r=48000" \
  -filter_complex "[0:a][1:a]amix=inputs=2,tremolo=f=2:d=0.4,volume=2.5[a]" -map "[a]" -ac 2 -c:a pcm_s16le music.wav
ffmpeg -v error -y -f lavfi -i "anoisesrc=d=20:c=brown:r=48000:a=0.01" -ac 2 -c:a pcm_s16le ambience.wav
ffmpeg -v error -y -f lavfi -i "testsrc2=size=640x360:rate=30:duration=20" -i ambience.wav \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest broll.mov

rm -f speech_raw.aiff
echo "$DUR" > duration.txt
ls -la
