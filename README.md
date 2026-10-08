# yt-dlp 网页一键脚本：贴链接，视频先留在 VPS

下好以后先留在 VPS。点「保存到本地」才下载到你正在用的电脑，浏览器完整收下后再删掉 VPS 上的文件。视频还可以压缩，或加上水印再压缩，然后保存到本地。参数写在 `新增需求.txt`。

## 安装（用 root 运行，一行）

```sh
sh -c 'c(){ command -v "$1" >/dev/null 2>&1; }; c curl || c wget || { for pm in "apk add --no-cache" "apt-get install -y" "dnf install -y" "yum install -y" "pacman -Sy --noconfirm" "zypper --non-interactive install" "opkg install"; do b=${pm%% *}; c $b || continue; [ "$b" = apt-get ] && { apt-get update -qq 2>/dev/null || sudo apt-get update -qq 2>/dev/null; }; $pm curl wget ca-certificates 2>/dev/null || sudo $pm curl wget ca-certificates 2>/dev/null; break; done; c curl || c wget || { echo "装不上 curl / wget，请手动装一个"; exit 1; }; }; ok=""; for u in https://raw.githubusercontent.com/imthnio/vps-ytdlp/main/install.sh https://cdn.jsdelivr.net/gh/imthnio/vps-ytdlp@main/install.sh; do (wget -qO /tmp/ytdlp-install.sh "$u" || curl -fsSL -o /tmp/ytdlp-install.sh "$u") 2>/dev/null && [ -s /tmp/ytdlp-install.sh ] && head -n 1 /tmp/ytdlp-install.sh | grep -q "^#!/bin/sh" && grep -q ytdlp-onekey-begin /tmp/ytdlp-install.sh && { ok=1; break; }; rm -f /tmp/ytdlp-install.sh; done; [ -n "$ok" ] || { echo "下载 install.sh 失败，请检查网络"; exit 1; }; sh /tmp/ytdlp-install.sh'
```

## 赞赏支持

如果这个脚本帮到了你，欢迎请我喝杯咖啡。

![赞赏码](./appreciate.png)
