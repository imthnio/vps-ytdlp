#!/bin/sh
# 假的 ffmpeg / ffprobe（看自己的名字决定扮演哪个），只给 test_server.sh 用。
# 文件名里有 .webm 的，假装是 VP9 + Opus（Mac 放不了，要转码）；其他假装是 H.264 + AAC。
# -encoders 时报有 libx265，给压缩按钮的检查用。两遍编码的第一遍输出是 /dev/null 或 -，不拷文件。
[ -n "${FAKE_LOG:-}" ] && echo "$(basename "$0") $*" >> "$FAKE_LOG"
case " $* " in
  *" -encoders "*|*" -encoders")
    printf '%s\n' ' V....D libx265              libx265 H.265 / HEVC'
    exit 0
    ;;
esac
last=; in=; prev=
for a in "$@"; do
  [ "$prev" = -i ] && in=$a
  prev=$a
  last=$a
done
case "$(basename "$0")" in
  ffprobe)
    case "$last" in
      *.webm) printf 'codec_name=vp9|codec_type=video|height=1080\ncodec_name=opus|codec_type=audio\nduration=30.000000\n' ;;
      *) printf 'codec_name=h264|codec_type=video|height=720\ncodec_name=aac|codec_type=audio\nduration=30.000000\n' ;;
    esac
    exit 0 ;;
esac
[ -n "$in" ] && [ -f "$in" ] || { echo "no input" >&2; exit 1; }
printf 'out_time_us=15000000\nprogress=continue\n'
sleep 0.3
case "$last" in
  -|/dev/null) ;;
  *) cp "$in" "$last" ;;
esac
printf 'out_time_us=30000000\nprogress=end\n'
