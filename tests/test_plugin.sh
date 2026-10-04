#!/bin/sh
# 不联网测我们自己的 yt-dlp 插件（ytdlp_web.py）：用假的页面喂给它，看它挑的地址和文件名对不对。
# 需要 python3；不需要装 yt-dlp（用一个很小的假 yt_dlp 模块代替）。
# 用法：sh tests/test_plugin.sh
cd "$(dirname "$0")/.." || exit 1
command -v python3 >/dev/null 2>&1 || { echo "没有 python3，跳过"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/yt_dlp/extractor"
sed -n "/<<'YTDLP_WEB_PLUGIN_EOF'$/,/^YTDLP_WEB_PLUGIN_EOF$/p" install.sh | sed '1d;$d' > "$T/ytdlp_web.py"
: > "$T/yt_dlp/__init__.py"
: > "$T/yt_dlp/extractor/__init__.py"
cat > "$T/yt_dlp/utils.py" <<'PY'
class ExtractorError(Exception):
    def __init__(self, msg, expected=False):
        super().__init__(msg)
PY
cat > "$T/yt_dlp/extractor/common.py" <<'PY'
import re
class InfoExtractor:
    def _match_valid_url(self, url):
        return re.match(self._VALID_URL, url)
    def _search_regex(self, pattern, string, name, default=None):
        m = re.search(pattern, string or '')
        return m.group(1) if m else default
PY
cd "$T" && python3 - <<'PY'
import json, sys
from ytdlp_web import YtdlpWebIE
from yt_dlp.utils import ExtractorError
fail = 0
def check(name, got, want):
    global fail
    if got == want: print('ok', name)
    else: print('FAIL', name, 'got', repr(got), 'want', repr(want), file=sys.stderr); fail = 1

class H:  # 假的网络回应
    def __init__(self, url): self.url = url

def douyin_page(item):
    data = {'loaderData': {'video_(id)/page': {'videoInfoRes': {'item_list': [item]}}}}
    return '<script>window._ROUTER_DATA = ' + json.dumps(data, ensure_ascii=False) + '</script>'

def run(item, link='https://www.douyin.com/video/7691993909329522314'):
    ie = YtdlpWebIE()
    ie._get = lambda url, vid, headers=None, note=None, fatal=True: (douyin_page(item), H(url))
    return ie._douyin(link)

play = {'url_list': ['https://aweme.snssdk.com/aweme/v1/playwm/?line=0&logo_name=aweme_diversion_search&ratio=720p&video_id=v0200abc']}
# 1) 没写描述：用「作者 的抖音 作品编号」；优先原分辨率（ratio=default），去水印
r = run({'aweme_id': '7691993909329522314', 'desc': '', 'author': {'nickname': 'glbl'},
         'video': {'play_addr': play, 'width': 496, 'height': 864, 'duration': 10055}})
check('dy-title-fallback', r['title'], 'glbl 的抖音 7691993909329522314')
best = max(r['formats'], key=lambda f: f.get('quality', 0))
check('dy-default-first', best['format_id'], 'nowm-default')
check('dy-nowm', '/playwm/' in best['url'], False)
check('dy-ratio-default', 'ratio=default' in best['url'], True)
check('dy-backup-1080p', any('ratio=1080p' in f['url'] for f in r['formats']), True)
check('dy-height', best['height'], 864)
# 2) 有描述：用描述，空白合并，最长 80 个字
r = run({'aweme_id': '1', 'desc': '  人和人的差距\n其实从小就开始了 #搞笑  ' + '长' * 100, 'author': {'nickname': 'x'},
         'video': {'play_addr': play}})
check('dy-title-desc', r['title'].startswith('人和人的差距 其实从小就开始了 #搞笑'), True)
check('dy-title-len', len(r['title']) <= 80, True)
# 3) 没作者也没描述
r = run({'aweme_id': '7', 'desc': '', 'video': {'play_addr': play}})
check('dy-title-noauthor', r['title'], '抖音 7691993909329522314')
# 4) 分享页给了 bit_rate 列表：都列出来，H.265 标成 hvc1
r = run({'aweme_id': '7', 'desc': 'a', 'video': {'play_addr': play, 'bit_rate': [
    {'gear_name': 'normal_1080_0', 'bit_rate': 3000000, 'is_h265': 1, 'play_addr': {'url_list': ['https://v/1080h265'], 'height': 1920}},
    {'gear_name': 'normal_720_0', 'bit_rate': 1500000, 'is_h265': 0, 'play_addr': {'url_list': ['https://v/720h264'], 'height': 1280}}]}})
codecs = {f['format_id']: f['vcodec'] for f in r['formats']}
check('dy-br-h265', codecs.get('br-normal_1080_0'), 'hvc1')
check('dy-br-h264', codecs.get('br-normal_720_0'), 'avc1')
# 5) 图文：多张图
r = run({'aweme_id': '7', 'desc': '图', 'images': [{'url_list': ['https://p/1.jpeg']}, {'url_list': ['https://p/2.jpeg']}]})
check('dy-images', (r['_type'], len(r['entries'])), ('playlist', 2))
# 6) 分享页没数据：报 YTWEB_NEED_COOKIES
ie = YtdlpWebIE()
ie._get = lambda url, vid, headers=None, note=None, fatal=True: ('<html>nothing</html>', H(url))
import ytdlp_web; ytdlp_web.time.sleep = lambda s: None
try:
    ie._douyin('https://www.douyin.com/video/7691993909329522314'); check('dy-need-cookies', 'no error', 'error')
except ExtractorError as e:
    check('dy-need-cookies', str(e).split()[0], 'YTWEB_NEED_COOKIES')
sys.exit(fail)
PY
[ $? -eq 0 ] || exit 1
printf '\n全部通过。\n'
