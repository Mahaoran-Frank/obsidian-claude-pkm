# 配方表 (recipes) — 已跑通的链接类型

> 每跑通一个新类型就 append 一条。命中这里的链接走快路径，不再从头推理。
> 一条配方 = 「特征 / 域名」+「怎么取文」+「注意事项」。

## 已知配方

| 平台 / 特征 | 取文路径 | 命令 / 做法 | 注意 |
|---|---|---|---|
| YouTube (`youtube.com` / `youtu.be`) | ② 字幕 | `transcribe.sh` | 几乎都有自动字幕，最省 |
| 哔哩哔哩 (`bilibili.com` / BV 号) | ② 字幕优先，无则 ③ | `transcribe.sh`（已内置） | **必须带 chrome cookie**（绕 412 风控，脚本对 bilibili 自动加 `--cookies-from-browser chrome`，Frank 已登录）；AI 字幕语言代码是 **`ai-zh`**，脚本已优先选中文。Safari cookie 读不了（需"完全磁盘访问"），用 Chrome |
| 博客 / 公众号 / Substack（纯文章页） | ① 正文 | Claude 用 `WebFetch` 抓正文转 md | 不进 transcribe.sh |

## 来源画像（Frank 的常用入口）

- 主力：B站（②类居多）。
- 第一性原理总则：**播客的本质 = RSS + 一个 mp3 enclosure，app 链接只是包装。**
  同一档播客若 app 链接难搞，去找它的 RSS 地址，enclosure 是裸 mp3，最稳。
