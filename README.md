# yt-dlp 网页一键脚本

在 Linux 小鸡上装好 [yt-dlp-web-ui](https://github.com/marcopiovanello/yt-dlp-web-ui)。装完以后，用 Mac 浏览器打开这台鸡，把 YouTube 链接贴进去，视频就在鸡上下载，再从网页存回 Mac。

不用 Docker。Docker 自己就占满 64MB 内存，小小鸡起不来。脚本改用官方的单个程序，缺的组件从这台鸡自己的软件源装，软件源里没有再下静态版本。

64MB 内存也能装。内存不到 768MB 时，会先做一块硬盘上的虚拟内存，并让下载一个接一个跑，避免两个视频一起把内存打爆。下载会比大机器慢。磁盘尽量留出 1GB，虚拟内存才够用。

安装时会用大白话问 6 个问题：端口、登录名字、密码、一次下几个视频、Mac 怎么打开、视频放在哪。除了端口，其他题直接按回车就是推荐选项。端口要你自己填一个数字，脚本不会替你定成 3033。已经装过的机器再运行时，端口直接回车会沿用你上次填的。

已经装好的机器再运行一次也安全：会更新程序，并再问一遍。这时直接回车会沿用你上次填的端口和密码。

## 安装（root，一行）

```sh
sh -c 'c(){ command -v "$1" >/dev/null 2>&1; }; c curl || c wget || { for pm in "apk add --no-cache" "apt-get install -y" "dnf install -y" "yum install -y" "pacman -Sy --noconfirm" "zypper --non-interactive install" "opkg install"; do b=${pm%% *}; c $b || continue; [ "$b" = apt-get ] && { apt-get update -qq 2>/dev/null || sudo apt-get update -qq 2>/dev/null; }; $pm curl wget ca-certificates 2>/dev/null || sudo $pm curl wget ca-certificates 2>/dev/null; break; done; c curl || c wget || { echo "装不上 curl / wget，请手动装一个"; exit 1; }; }; ok=""; for u in https://raw.githubusercontent.com/imthnio/vps-ytdlp/main/install.sh https://cdn.jsdelivr.net/gh/imthnio/vps-ytdlp@main/install.sh; do (wget -qO /tmp/ytdlp-install.sh "$u" || curl -fsSL -o /tmp/ytdlp-install.sh "$u") 2>/dev/null && [ -s /tmp/ytdlp-install.sh ] && head -n 1 /tmp/ytdlp-install.sh | grep -q "^#!/bin/sh" && grep -q ytdlp-onekey-begin /tmp/ytdlp-install.sh && { ok=1; break; }; rm -f /tmp/ytdlp-install.sh; done; [ -n "$ok" ] || { echo "下载 install.sh 失败，请检查网络"; exit 1; }; sh /tmp/ytdlp-install.sh'
```

一行会先确认有 curl 或 wget，没有就用系统软件源装上，再从 GitHub 和 jsDelivr 里挑一个能用的地址下载。

小鸡要能自己打开 YouTube 和 GitHub。大陆机器通常打不开 YouTube。

## 它会自己看什么

- 系统：Debian、Ubuntu 及其衍生版、CentOS / RHEL / Rocky / Alma / Fedora、Alpine、Arch、openSUSE、OpenWrt、Void。按这台鸡实际的包管理器安装，认不出就说明缺什么。
- 架构：amd64、arm64、armv7、armv6。32 位 x86 没有这个网页程序，会直接停下。
- 系统库：glibc 还是 musl。Alpine 用 musl 版的 yt-dlp。
- 内存和硬盘：内存不到 768MB，并且磁盘腾得出来，就加虚拟内存。`/var` 如果在内存盘上，数据改放到根目录，避免下载把内存盘写满。
- 启动方式：systemd、OpenRC、OpenWrt 的 procd，或者其他 SysV。装好后开机自己起来。

## 它会自己装什么

- 网页程序 yt-dlp-web-ui
- yt-dlp。内存够的鸡用官方单文件。内存在 256MB 及以下时，那个 40MB 的单文件一运行就会把鸡撑死，改用小的 Python 版
- ffmpeg、ffprobe（合并画面和声音。软件源没有就下静态版本）
- QuickJS（YouTube 现在要一个 JavaScript 运行时来算签名。这个静态程序大约 2MB，64MB 的鸡跑得动）
- 证书、curl、tar、解压工具。已经有的不重复装
- 登录。你可以让脚本随机生成密码，也可以自己设一个。打开网页前要先登录。密码记在 `/etc/yt-dlp-webui/install.txt`

端口由你来定，第一次安装必须自己填，没有默认的 3033。这个端口已经被别的程序占用时，会请你再输入一个，不会自己偷偷改掉。你如果选了“浏览器直接打开”，并且本机防火墙开着，脚本会放开这个 TCP 端口。选了“只用 SSH 转发”就不会放开。

## 在 Mac 上用

公网小鸡如果选了“浏览器直接打开”，终端里会印出地址，形如 `http://小鸡IP:你设的端口`。用浏览器打开，输入你设的登录名字（直接回车则是 `admin`）和密码，把 YouTube 链接贴进去。

视频先下到小鸡。下完后在网页里把文件再下回 Mac。小鸡硬盘通常不大，存回 Mac 之后把鸡上的文件删掉。

NAT 小鸡外面不能直接打开。安装时选“用 SSH 转发”，按终端里印出的 `ssh -L` 那一行，从 Mac 转发到本机再打开 `http://127.0.0.1:你设的端口`。服务商面板如果有端口映射，安装时选第 1 项，把公网端口转到小鸡上你设的那个端口。

## 其它命令

第一次成功之后可以直接输入 `ytdlp-web`。

```sh
ytdlp-web                   # 更新程序。每题直接回车就沿用现在的设置
ytdlp-web --status          # 查看系统、密码、是否在运行
ytdlp-web --reset-password  # 换一把登录密码
ytdlp-web --uninstall       # 先问一句再卸。直接回车不卸。视频留着
```

## 赞赏支持

如果这个脚本帮到了你，欢迎请我喝杯咖啡。

![赞赏码](./appreciate.png)
