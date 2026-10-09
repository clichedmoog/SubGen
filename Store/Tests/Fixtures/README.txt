video.webm is a synthetic two-second black image and 440 Hz tone.
No personal media or account data is used. VP9/Opus exercise remuxing and
WebVTT subtitle embedding without requiring encoders in the shipped tool.

Reproduce on a build machine with FFmpeg/libvpx/libopus:
ffmpeg -f lavfi -i color=c=black:size=160x90:duration=2 \
  -f lavfi -i sine=frequency=440:duration=2 \
  -c:v libvpx-vp9 -c:a libopus -shortest video.webm
