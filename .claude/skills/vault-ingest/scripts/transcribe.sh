#!/usr/bin/env bash
# transcribe.sh — 把一个媒体链接转成带时间戳的 Markdown 逐字稿
#
# 第一性原理：一个链接背后只有三种东西——
#   ① 文字本来就在页面里（博客/公众号/Substack）→ 不归这个脚本管，走 WebFetch
#   ② 音视频【有字幕】（B站AI字幕 / YouTube CC）→ 抓字幕（最快最准最省）
#   ③ 音视频【没字幕】→ 扒音频 → whisper 转写（慢，但能兜底）
# 本脚本负责 ② 和 ③。
#
# 用法: transcribe.sh <URL> <输出目录> [标题提示]
# 成功: 退出 0，最后一行打印  OUTPUT=<生成的md路径>
# 失败: 退出非 0，打印  REASON=<人话原因>  —— 调用方据此写入 failures.md 并告诉用户
#
# 环境变量:
#   WHISPER_MODEL  默认 medium；想更快用 large-v3-turbo / distil-large-v3.5；想更准用 large-v3

set -uo pipefail

URL="${1:?需要 URL}"
OUTDIR="${2:?需要输出目录}"
TITLE="${3:-}"
WHISPER_MODEL="${WHISPER_MODEL:-medium}"

YTDLP="$(command -v yt-dlp || echo /opt/homebrew/bin/yt-dlp)"
WHISPER="$(command -v whisper-ctranslate2 || echo "$HOME/.local/bin/whisper-ctranslate2")"

# Cookie 处理（绕过 B站 412 风控等）。优先级：显式文件 > 显式浏览器 > 按域名兜底。
#   COOKIES_FILE=<path>        用导出的 cookies.txt
#   COOKIES_BROWSER=chrome|... 从指定浏览器读
#   默认：bilibili 链接自动用 chrome（用户已登录），其余不带
COOKIE_ARGS=()
if [ -n "${COOKIES_FILE:-}" ]; then
  COOKIE_ARGS=(--cookies "$COOKIES_FILE")
elif [ -n "${COOKIES_BROWSER:-}" ]; then
  COOKIE_ARGS=(--cookies-from-browser "$COOKIES_BROWSER")
elif printf '%s' "$URL" | grep -qi 'bilibili\.com'; then
  COOKIE_ARGS=(--cookies-from-browser chrome)
fi
# 包一层，自动注入 cookie 参数；空数组在 bash 3.2 + set -u 下需用 +- 守卫
ytdlp() { "$YTDLP" "${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"}" "$@"; }

mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[transcribe] URL=$URL"

# 0. yt-dlp 认不认这个链接？不认 → 大概率是纯文章页或被登录/DRM挡，交回上层走 WebFetch
if ! ytdlp --simulate --quiet --no-warnings "$URL" >/dev/null 2>&1; then
  echo "REASON=yt-dlp 不认识这个链接（可能是纯文章页，应走 WebFetch；或需要登录cookie / 被DRM挡，如 Spotify）"
  exit 3
fi

# 拿标题用于文件名
if [ -z "$TITLE" ]; then
  TITLE="$(ytdlp --get-title --no-warnings "$URL" 2>/dev/null | head -1)"
fi
[ -z "$TITLE" ] && TITLE="untitled"
SAFE="$(printf '%s' "$TITLE" | tr -d '/\\:*?"<>|' | cut -c1-60)"

# 1. 先试字幕（case ②）
echo "[transcribe] 尝试抓字幕..."
# 注意 B站 AI 字幕的语言代码是 ai-zh / ai-en，必须显式列出
ytdlp --skip-download \
  --write-subs --write-auto-subs \
  --sub-langs "ai-zh,zh-Hans,zh-CN,zh,ai-en,en,en-US" \
  --convert-subs srt \
  -o "$TMP/sub.%(ext)s" \
  "$URL" >/dev/null 2>&1 || true

# 优先中文字幕（ai-zh / zh），实在没有再退英文，避免抓到 ai-en 翻译稿
SRT="$(ls "$TMP"/*ai-zh*.srt "$TMP"/*.zh*.srt "$TMP"/*zh-*.srt 2>/dev/null | head -1 || true)"
[ -z "$SRT" ] && SRT="$(ls "$TMP"/*.srt 2>/dev/null | head -1 || true)"

if [ -n "$SRT" ]; then
  SRC="字幕"
else
  # 2. 没字幕 → 扒音频 → whisper（case ③）
  echo "[transcribe] 无字幕，下载音频..."
  ytdlp -f bestaudio -x --audio-format mp3 \
    -o "$TMP/audio.%(ext)s" "$URL" >/dev/null 2>&1 || true
  AUDIO="$(ls "$TMP"/audio.* 2>/dev/null | head -1 || true)"
  if [ -z "$AUDIO" ]; then
    echo "REASON=既无字幕、也下不到音频（可能需要登录cookie / 被DRM挡）"
    exit 4
  fi
  DUR="$(ytdlp --get-duration --no-warnings "$URL" 2>/dev/null | head -1)"
  echo "[transcribe] whisper 转写中 (model=$WHISPER_MODEL, 时长≈${DUR:-未知}, CPU 上约为时长的 0.5~1.5 倍耗时，请耐心等)..."
  "$WHISPER" "$AUDIO" \
    --model "$WHISPER_MODEL" --language zh --task transcribe \
    --compute_type int8 --vad_filter True \
    --output_format srt --output_dir "$TMP" >/dev/null 2>&1 || true
  SRT="$(ls "$TMP"/audio.srt 2>/dev/null | head -1 || true)"
  [ -z "$SRT" ] && SRT="$(ls "$TMP"/*.srt 2>/dev/null | head -1 || true)"
  if [ -z "$SRT" ]; then
    echo "REASON=whisper 转写失败（音频已下到，但转写没产出 srt）"
    exit 5
  fi
  SRC="whisper(${WHISPER_MODEL})"
fi

# 3. SRT → 带时间戳的 Markdown，去重相邻重复行
OUT="$OUTDIR/原材料_${SAFE}_逐字稿.md"
python3 - "$SRT" "$TITLE" "$URL" "$SRC" > "$OUT" <<'PY'
import sys, re
srt, title, url, src = sys.argv[1:5]
def ts(t):
    h, m, rest = t.split(':')
    s = rest.split(',')[0].split('.')[0]
    tot = int(h)*3600 + int(m)*60 + int(s)
    return f"{tot//60}:{tot%60:02d}"
raw = open(srt, encoding='utf-8', errors='ignore').read().strip()
blocks = re.split(r'\n\s*\n', raw)
print(f"# 原材料：{title}\n")
print(f"- 来源：{url}")
print(f"- 转写方式：{src}")
print("\n---\n")
last = None
for b in blocks:
    lines = [l for l in b.splitlines() if l.strip()]
    if len(lines) < 2:
        continue
    m = re.search(r'(\d+:\d+:\d+[,.]\d+)\s*-->', b)
    stamp = ts(m.group(1)) if m else ''
    body = lines[2:] if re.match(r'^\d+$', lines[0]) else lines[1:]
    text = ' '.join(body).strip()
    text = re.sub(r'<[^>]+>', '', text)  # 去掉字幕里的样式标签
    if not text or text == last:
        continue
    last = text
    print(f"[{stamp}] {text}")
PY

echo "SOURCE_METHOD=$SRC"
echo "OUTPUT=$OUT"
exit 0
