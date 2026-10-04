#!/bin/sh
# 假的 yt-dlp，只给 test_server.sh 用。
# 按链接里的关键字假装：成功、被拦（要 cookies）、年龄限制、视频被删、
# 图文帖（好几张图）、纯文字帖、推特没有视频、只有 VP9 的视频（要转码）。
for a in "$@"; do
  case "$a" in
    -U) echo "yt-dlp is up to date (fake)"; exit 0 ;;
    --version) echo 2026.08.19; exit 0 ;;
  esac
done
home=; url=; ck=0; prev=
for a in "$@"; do
  case "$prev" in --paths) case "$a" in home:*) home=${a#home:} ;; esac ;; esac
  [ "$a" = --cookies ] && ck=1
  prev=$a
  url=$a
done
[ -n "${FAKE_LOG:-}" ] && echo "$@" >> "$FAKE_LOG"
case "$url" in
  *bot*) if [ "$ck" = 0 ]; then echo "ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies"; exit 1; fi ;;
  *age*) echo "ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users."; exit 1 ;;
  *gone*) echo "ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader"; exit 1 ;;
  ytweb:douyin:*needck*)
    if [ "$ck" = 0 ]; then echo "ERROR: [ytweb] YTWEB_NEED_COOKIES douyin share page has no data"; exit 1; fi ;;
  *douyin*needck*) echo "ERROR: [Douyin] 123: Fresh cookies (not necessarily logged in) are needed"; exit 1 ;;
  ytweb:ximg:*text*) echo "ERROR: [ytweb] YTWEB_NO_MEDIA"; exit 1 ;;
  ytweb:ximg:*|ytweb:xhs:*img*)
    for n in 01 02 03; do
      echo "TITLE 图文：第一篇"
      f="$home/图文：第一篇 $n.jpg"
      head -c 20000 /dev/urandom > "$f"
      echo "PROG 20000 20000 NA 1000 0"
      echo "FILE $f"
    done
    exit 0 ;;
  *x.com*|*twitter.com*) echo "ERROR: [twitter] 123: No video could be found in this tweet"; exit 1 ;;
esac
ext=mp4
case "$url" in *vp9*) ext=webm ;; esac
echo "TITLE 测试视频：中文/标题 \"引号\""
f="$home/测试视频：中文 标题.$ext"
head -c 3145728 /dev/urandom > "$f.part"
for p in 10 50 90; do echo "PROG $((p * 31457)) 3145728 NA 1048576.5 2"; sleep 0.2; done
mv "$f.part" "$f"
echo "POST Merger"
echo "FILE $f"
