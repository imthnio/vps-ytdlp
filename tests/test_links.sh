#!/bin/sh
# 不开网页、不联网，只测网页服务里的几个小函数：
# 从分享文字里挑网址、认平台、剥追踪参数、cookies 按平台分、英文报错翻成中文、zip 打包。
# 用法：sh tests/test_links.sh
cd "$(dirname "$0")/.." || exit 1
command -v perl >/dev/null 2>&1 || { echo "没有 perl，跳过"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
sed -n "/<<'YTDLP_WEB_SERVER_EOF'$/,/^YTDLP_WEB_SERVER_EOF$/p" install.sh | sed '1d;$d' > "$T/server.pl"
printf 'port=1\npass_hash=$6$x$y\ndata=%s/data\ncookies=%s/cookies.txt\nlog=%s/log\n' "$T" "$T" "$T" > "$T/web.conf"
YTDLP_WEB_NO_MAIN=1 T="$T" perl -e '
  @ARGV = ("$ENV{T}/web.conf");
  do "$ENV{T}/server.pl" or die "load: $@ $!";
  my $fail = 0;
  sub is { my ($n, $got, $want) = @_; $got = "" unless defined $got;
    if ($got eq $want) { print "ok $n\n" } else { print STDERR "FAIL $n got [$got] want [$want]\n"; $fail = 1 } }
  sub like { my ($n, $got, $re) = @_; $got = "" unless defined $got;
    if ($got =~ $re) { print "ok $n\n" } else { print STDERR "FAIL $n [$got] !~ $re\n"; $fail = 1 } }

  # 用户给的真分享文字
  my $dy = "6.99 复制打开抖音，看看【有点意思的作品】人和人的差距 # 搞笑 # 日常 https://v.douyin.com/qZn98J7Dp00/ 8\@5.com :2pm 03/21 fBt:/ Jvs:/";
  is("douyin-share", (check_url($dy))[0], "https://v.douyin.com/qZn98J7Dp00/");
  my $xhs = "一口气带你认识各种各样的楼 http://xhslink.cn/o/AahIzgf95oX 复制后打开【小红书】查看笔记！";
  is("xhs-share", (check_url($xhs))[0], "https://xhslink.cn/o/AahIzgf95oX");
  is("xhs-plat", platform_of("http://xhslink.cn/o/AahIzgf95oX"), "xhs");
  is("xhs-long-keep-token", (check_url("https://www.xiaohongshu.com/discovery/item/6ac217cf000000001500e6d8?type=video&xsec_token=CBB12x="))[0],
    "https://www.xiaohongshu.com/discovery/item/6ac217cf000000001500e6d8?type=video&xsec_token=CBB12x=");
  is("bili-clean", (check_url("https://www.bilibili.com/video/BV1tHaA6qEXL/?trackid=web_pegasus_0.router-web-pegasus-2479516-f6fct.1791128443880.967&spm_id_from=333.1007.tianma.3-4-10.click&vd_source=bb26ce30756da1f2b9de51fa1d1980d1"))[0],
    "https://www.bilibili.com/video/BV1tHaA6qEXL/");
  is("bili-page", (check_url("https://m.bilibili.com/video/BV1bK411W797?p=2&share_source=copy"))[0], "https://www.bilibili.com/video/BV1bK411W797/?p=2");
  is("bili-share-text", (check_url("【标题】 https://b23.tv/AbCdEf1"))[0], "https://b23.tv/AbCdEf1");
  is("bili-plat", platform_of("https://b23.tv/AbCdEf1"), "bili");
  is("ig-clean", (check_url("https://www.instagram.com/p/Ddr-AMmDxqn/?stkn=MTl2emdjbXY4OGMxOQ=="))[0], "https://www.instagram.com/p/Ddr-AMmDxqn/");
  is("ig-plat", platform_of("https://www.instagram.com/p/Ddr-AMmDxqn/"), "ig");
  is("tiktok-short", (check_url("https://www.tiktok.com/t/ZPLR4LN5f/"))[0], "https://www.tiktok.com/t/ZPLR4LN5f/");
  is("tiktok-plat", platform_of("https://vm.tiktok.com/ZPLR4LN5f/"), "tiktok");
  is("x-clean", (check_url("https://x.com/vivienyxxx/status/2106683215293657589?s=46"))[0], "https://x.com/vivienyxxx/status/2106683215293657589");
  is("x-photo", (check_url("https://twitter.com/a/status/123/photo/1"))[0], "https://twitter.com/a/status/123");
  is("x-plat", platform_of("https://twitter.com/a/status/123"), "x");
  is("yt-same", (check_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc"))[0], "https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc");
  is("yt-bare", (check_url("youtu.be/dQw4w9WgXcQ"))[0], "https://youtu.be/dQw4w9WgXcQ");
  is("yt-plat", platform_of("https://youtu.be/x"), "youtube");
  is("box-not-x", platform_of("https://dropbox.com/s/a"), "other");
  is("bare-not-x", extract_link("看看 inbox.com/abc"), "");
  is("trailing-punct", extract_link("链接：https://youtu.be/abc123。"), "https://youtu.be/abc123");
  is("trailing-paren", extract_link("(https://youtu.be/abc123)"), "https://youtu.be/abc123");
  like("no-url", (check_url("复制打开抖音，看看"))[1], qr/不像网址/);
  like("empty", (check_url("  "))[1], qr/粘贴/);
  like("yt-playlist", (check_url("https://www.youtube.com/playlist?list=PL1"))[1], qr/播放列表/);
  like("douyin-user", (check_url("https://www.douyin.com/user/MS4wLjAB"))[1], qr/主页/);

  # cookies 按平台
  is("ck-yt", cookie_plat(".youtube.com"), "youtube");
  is("ck-httponly", cookie_plat("#HttpOnly_.douyin.com"), "douyin");
  is("ck-xhs", cookie_plat("www.xiaohongshu.com"), "xhs");
  is("ck-bili", cookie_plat(".bilibili.com"), "bili");
  is("ck-x", cookie_plat(".x.com"), "x");
  is("ck-other", cookie_plat(".example.com"), "");
  my ($e1) = save_cookies(".example.com\tTRUE\t/\tFALSE\t0\ta\tb\n");
  like("ck-unknown", $e1, qr/认得出/);
  my ($e2, $n2) = save_cookies("#HttpOnly_.bilibili.com\tTRUE\t/\tFALSE\t0\tSESSDATA\tb\n.tiktok.com\tTRUE\t/\tFALSE\t0\tsid\tc\n");
  is("ck-save", $e2, "");
  is("ck-names", join(",", @$n2), "B站,TikTok");
  save_cookies(".bilibili.com\tTRUE\t/\tFALSE\t0\tbuvid3\tnew\n");
  my $ck = slurp("$ENV{T}/cookies.txt");
  like("ck-replace-plat", $ck, qr/buvid3/);
  is("ck-old-plat-gone", ($ck =~ /SESSDATA/ ? 1 : 0), 0);
  like("ck-other-kept", $ck, qr/tiktok/);
  is("has-ck-bili", has_cookies("bili"), 1);
  is("has-ck-yt", has_cookies("youtube"), 0);

  # 报错翻译
  is("cls-douyin", (classify("ERROR: [Douyin] 1: Fresh cookies (not necessarily logged in) are needed", 0, "douyin"))[0], "blocked");
  like("cls-douyin-msg", (classify("ERROR: [Douyin] 1: Fresh cookies (not necessarily logged in) are needed", 0, "douyin"))[1], qr/抖音/);
  is("cls-bili-412", (classify("ERROR: [BiliBili] x: Unable to download webpage: HTTP Error 412: Precondition Failed", 0, "bili"))[0], "blocked");
  is("cls-x-novideo", (classify("ERROR: [twitter] 1: No video could be found in this tweet", 0, "x"))[0], "no_video");
  like("cls-nomedia", (classify("ERROR: [ytweb] YTWEB_NO_MEDIA", 0, "x"))[1], qr/没有视频也没有图片/);
  like("cls-gone", (classify("ERROR: [ytweb] YTWEB_GONE", 0, "xhs"))[1], qr/删除/);
  like("cls-need", (classify("ERROR: [ytweb] YTWEB_NEED_COOKIES xhs login page", 0, "xhs"))[1], qr/小红书/);
  is("cls-need-hint", (classify("ERROR: [ytweb] YTWEB_NEED_COOKIES xhs login page", 0, "xhs"))[2], "cookies");
  like("cls-ig-login", (classify("ERROR: [Instagram] x: Requested content is not available, rate-limit reached or login required", 0, "ig"))[1], qr/Instagram/);
  like("cls-tiktok-ip", (classify("ERROR: [TikTok] 1: Your IP address is blocked from accessing this post", 0, "tiktok"))[1], qr/TikTok/);
  like("cls-geo", (classify("ERROR: [BiliBili] 1: This video is not available in your country (geo restricted)", 0, "bili"))[1], qr/国家/);
  like("cls-timeout", (classify("ERROR: [TikTok] 1: timed out", 0, "tiktok"))[1], qr/TikTok/);
  like("cls-yt-same", (classify("ERROR: [youtube] x: Sign in to confirm you’re not a bot", 0, "youtube"))[1], qr/YouTube 认为/);
  is("cls-oom", (classify("", 9, "bili"))[0], "fatal");

  # 方法表：YouTube 照旧以直接下载开头；其他平台每一步都写明走哪种网络
  my @yt = map { $_->{key} } all_methods("youtube");
  is("yt-methods", join(",", @yt[0..2]), "direct,clients,ipv6");
  my @xm = grep { $_->{ok} } all_methods("xhs");
  like("xhs-helper", join(",", map { $_->{helper} } @xm), qr/^(xhs,?)*$/);
  is("xhs-ip-label", (grep { !$_->{ip} } all_methods("tiktok")) ? "missing" : "ok", "ok");
  like("q-other", join(" ", quality_args("mac", "ig")), qr/vcodec\^=avc/);
  is("q-yt", join(" ", quality_args("mac", "youtube")), "-f b -S vcodec:h264,res,acodec:aac --merge-output-format mp4");

  # zip：标准格式，中文名
  mkdir "$ENV{T}/z"; open my $f, ">", "$ENV{T}/z/图1.jpg"; print $f "abc" x 1000; close $f;
  open $f, ">", "$ENV{T}/z/图2.jpg"; print $f "xyz"; close $f;
  is("zip-n", make_zip("$ENV{T}/z/a.zip", "$ENV{T}/z", "图1.jpg", "图2.jpg"), 2);
  is("crc", sprintf("%08x", crc32_update(0, "123456789")), "cbf43926");
  is("est-720", transcode_estimate(100, 720), 130);
  exit $fail;
' || exit 1
if command -v python3 >/dev/null 2>&1; then
  python3 - "$T/z/a.zip" <<'PY' || exit 1
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
assert z.testzip() is None
assert z.namelist() == ['图1.jpg', '图2.jpg'], z.namelist()
assert z.read('图1.jpg') == b'abc' * 1000
print('ok zip-python')
PY
fi
printf '\n全部通过。\n'
