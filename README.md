# yt-dlp 网页一键脚本：贴链接，视频自动存进 Mac

在 Linux VPS 上运行一行命令，装好一个中文小网页。以后在 Mac 浏览器里打开它，**把 YouTube 链接贴进去，视频就会自动存进 Mac 的「下载」文件夹**。传完以后 VPS 上的文件自动删掉，不占你 VPS 的硬盘，也不用你自己去删。

整个流程：

1. Mac 浏览器打开 `http://你的VPS的IP:端口`，输入名字和密码登录
2. 贴 YouTube 链接，选画质（不懂就用默认的「Mac 能直接播放」），点「开始」
3. VPS 先下好，网页自动把视频交给浏览器保存到 Mac。Safari 第一次会问「是否允许下载」，点「允许」
4. 传完 2 分钟后，VPS 上的这个文件自动删除

不用 Docker，不用装 Python。网页服务只有一个小 Perl 程序，平时只占大约 5MB 内存。64MB 内存的小鸡也能装：内存不够时会自动加一块硬盘上的虚拟内存，视频一次只下一个。

## 安装（用 root 运行，一行）

```sh
sh -c 'c(){ command -v "$1" >/dev/null 2>&1; }; c curl || c wget || { for pm in "apk add --no-cache" "apt-get install -y" "dnf install -y" "yum install -y" "pacman -Sy --noconfirm" "zypper --non-interactive install" "opkg install"; do b=${pm%% *}; c $b || continue; [ "$b" = apt-get ] && { apt-get update -qq 2>/dev/null || sudo apt-get update -qq 2>/dev/null; }; $pm curl wget ca-certificates 2>/dev/null || sudo $pm curl wget ca-certificates 2>/dev/null; break; done; c curl || c wget || { echo "装不上 curl / wget，请手动装一个"; exit 1; }; }; ok=""; for u in https://raw.githubusercontent.com/imthnio/vps-ytdlp/main/install.sh https://cdn.jsdelivr.net/gh/imthnio/vps-ytdlp@main/install.sh; do (wget -qO /tmp/ytdlp-install.sh "$u" || curl -fsSL -o /tmp/ytdlp-install.sh "$u") 2>/dev/null && [ -s /tmp/ytdlp-install.sh ] && head -n 1 /tmp/ytdlp-install.sh | grep -q "^#!/bin/sh" && grep -q ytdlp-onekey-begin /tmp/ytdlp-install.sh && { ok=1; break; }; rm -f /tmp/ytdlp-install.sh; done; [ -n "$ok" ] || { echo "下载 install.sh 失败，请检查网络"; exit 1; }; sh /tmp/ytdlp-install.sh'
```

这一行会先确认有 curl 或 wget（没有就自动装），再从 GitHub 或 jsDelivr 下载脚本运行。VPS 要能打开 YouTube 和 GitHub。大陆机器通常打不开 YouTube。

### 全自动安装（一个问题都不问）

在上面那一行最前面加上 `PORT=你的端口 `（注意后面有个空格），就不再提问：登录名字是 `admin`，密码随机生成，最后醒目地印出「网址、登录名、密码」三样。例如端口 15346：

```sh
PORT=15346 sh -c 'c(){ command -v "$1" >/dev/null 2>&1; }; c curl || c wget || { for pm in "apk add --no-cache" "apt-get install -y" "dnf install -y" "yum install -y" "pacman -Sy --noconfirm" "zypper --non-interactive install" "opkg install"; do b=${pm%% *}; c $b || continue; [ "$b" = apt-get ] && { apt-get update -qq 2>/dev/null || sudo apt-get update -qq 2>/dev/null; }; $pm curl wget ca-certificates 2>/dev/null || sudo $pm curl wget ca-certificates 2>/dev/null; break; done; c curl || c wget || { echo "装不上 curl / wget，请手动装一个"; exit 1; }; }; ok=""; for u in https://raw.githubusercontent.com/imthnio/vps-ytdlp/main/install.sh https://cdn.jsdelivr.net/gh/imthnio/vps-ytdlp@main/install.sh; do (wget -qO /tmp/ytdlp-install.sh "$u" || curl -fsSL -o /tmp/ytdlp-install.sh "$u") 2>/dev/null && [ -s /tmp/ytdlp-install.sh ] && head -n 1 /tmp/ytdlp-install.sh | grep -q "^#!/bin/sh" && grep -q ytdlp-onekey-begin /tmp/ytdlp-install.sh && { ok=1; break; }; rm -f /tmp/ytdlp-install.sh; done; [ -n "$ok" ] || { echo "下载 install.sh 失败，请检查网络"; exit 1; }; sh /tmp/ytdlp-install.sh'
```

还可以一起加（都可以不加）：`WEB_USER=名字`、`WEB_PASS=密码`（至少 6 位）、`OPEN=2`（只用 SSH 转发）、`WARP=0`（不用 Cloudflare WARP）。已经装过的机器用全自动模式，就是按原来的设置更新，密码不变。

## 安装时的 5 个问题

除了第 1 题，其他直接按回车就是推荐的选项。

| 题目 | 怎么答 |
| --- | --- |
| 1. 网页端口 | **必须自己填**一个数字，例如 8080。服务商给你开了哪个端口就填哪个。不能填 22。被别的程序占用时会请你换一个 |
| 2. 登录名字 | 直接回车，就是 `admin` |
| 3. 登录密码 | 直接回车，随机生成一把（装完会显示）。也可以选 2 自己设 |
| 4. Mac 怎么打开 | 直接回车，浏览器直接打开。选 2 是只用 SSH 转发，更安全但每次要先敲一行命令 |
| 5. 被拦时用 Cloudflare WARP | 直接回车，要。平时不开，被 YouTube 拦住时才临时打开 |

最后会把你的选择列出来，回车开始装。装完会显示网址、名字和密码。

## 它会自己做什么

- **认系统**：Debian、Ubuntu 和它们的衍生版、CentOS / RHEL / Rocky / Alma / Fedora、Alpine、Arch、openSUSE、OpenWrt、Void。按这台机器自己的软件源装东西
- **认架构**：amd64、arm64、armv7、armv6、386。glibc 和 musl（Alpine）都行
- **小内存**：内存加虚拟内存不到 768MB 时，在硬盘上做一块虚拟内存（`/ytdlp-web.swap`）。视频一个接一个下
- **装的东西**：yt-dlp（每天自动更新）、ffmpeg（合并画面和声音）、QuickJS（YouTube 现在要一个 JavaScript 运行时来解题，QuickJS 程序只有 2.5MB，比 deno 的 96MB 小得多，yt-dlp 官方支持）、PO 令牌程序（内存加虚拟内存够 300MB 才装）、Cloudflare WARP（你选了才装）
- **开机自启**：systemd、OpenRC、OpenWrt 的 procd、其他 SysV 都行
- **防火墙**：选了「浏览器直接打开」，本机防火墙开着时会放开这个端口

## 被 YouTube 拦住了怎么办（「请登录，确认你不是机器人」）

VPS 是机房的 IP，YouTube 有时会拦。**网页会自动按顺序换办法，你什么都不用做**：

1. 直接下载
2. 换一种 YouTube 客户端再试（android_vr、web_safari、tv 等，不用账号）
3. 这台 VPS 有 IPv6 的话，改走 IPv6
4. 自动算 PO 令牌再试（内存加虚拟内存够 300MB、64 位 glibc 的机器才有）
5. 换成 Cloudflare WARP 的出口 IP 再试（你装的时候选了「要」才有。用户态程序，不需要 TUN，容器里也能用）
6. 上面都不行，才用你上传的 cookies

另外：哪个办法成功了，接下来 24 小时先用它；第一次被拦时会先把 yt-dlp 更新到最新版再试。

全都失败时，网页会用中文告诉你怎么上传 cookies。**请用小号**，因为用 cookies 下载有被 YouTube 封号的风险。导出方法：

1. 在电脑浏览器开一个**无痕/隐私窗口**，登录你的 YouTube 小号
2. 在这个窗口打开 `https://www.youtube.com/robots.txt`
3. 用浏览器扩展「Get cookies.txt LOCALLY」导出 cookies.txt
4. **马上关掉这个无痕窗口**（不要再在里面点 YouTube，不然 cookies 会很快失效）
5. 在网页底部「上传 cookies」那里选这个文件，或者把内容粘贴进去

cookies 过一段时间会失效，网页会提醒你重新上传。机房 IP 被拦有时会持续几天到几周，换不同的办法也不一定都有效。

## 在 Mac 上打开

- **有公网 IP**：浏览器打开 `http://VPS的IP:端口`
- **NAT 小鸡 / 容器**：服务商面板里把外网端口映射到这台机器的同一个端口，安装时选 1。没有端口映射就选 2（SSH 转发），然后每次在 Mac 终端执行 `ssh -L 端口:127.0.0.1:端口 root@VPS的IP`，不要关窗口，浏览器打开 `http://127.0.0.1:端口`

## 其它命令

装好以后可以直接输入 `ytdlp-web`：

```sh
ytdlp-web                   # 已经装过：直接回车就是更新到最新版本。选 2 才改端口、密码等设置
ytdlp-web --status          # 看系统、各组件、网址、名字和密码、是否在运行
ytdlp-web --log             # 看最近的运行记录
ytdlp-web --reset-password  # 换一把登录密码
ytdlp-web --uninstall       # 先问一句再卸。直接回车不卸
```

从旧版（视频下到 VPS 的 1.x 版）升级：再运行一次安装命令，回车就行。端口和密码沿用，旧版的程序会被清掉。旧版下在 VPS 上的视频不会删，会告诉你在哪个目录。

## 常见问题

- **点了开始，Mac 上没有出现文件？** 看浏览器有没有弹出「是否允许下载」，点允许。也可以点任务旁边的「保存到 Mac」。只有贴链接的那个浏览器会自动保存
- **Chrome 提示「不安全的下载」？** Chrome 打开了「始终使用安全连接」时，从 http 网址下载会提示。点「保留」就行，或者改用 SSH 转发（127.0.0.1 不会提示）
- **想下 4K？** 画质选「最高画质」。这种文件 QuickTime 可能放不了，可以用 IINA 或 VLC
- **一直没传到 Mac 的视频会怎样？** 6 小时后自动删掉
- **报「内存不够」？** 运行 `ytdlp-web` 回车更新一次，脚本会重新配虚拟内存。或者换低一点的画质
- **年龄限制或会员视频？** 必须登录才能看，需要上传 cookies

## 文件放在哪

- 设置：`/etc/ytdlp-web/web.conf`，名字和密码：`/etc/ytdlp-web/install.txt`
- 临时视频：`/var/lib/ytdlp-web/jobs/`（传完自动删）
- 运行记录：`/var/log/ytdlp-web.log`

网页服务用 root 运行。请用强密码，或者用 SSH 转发方式。

## 赞赏支持

如果这个脚本帮到了你，欢迎请我喝杯咖啡。

![赞赏码](./appreciate.png)
