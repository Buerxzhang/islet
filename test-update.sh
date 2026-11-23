#!/bin/zsh
# 本地测试应用内更新：不发版、不碰 GitHub，走一遍「弹窗 → 下载 → 重启替换」。
# 用法：./test-update.sh        （Ctrl-C 结束，会恢复成查 GitHub）
# 做的事：
#   1. 用当前代码构建一个版本号 +.1 的“新版”（如 1.4.2.1），打成 islet.zip
#   2. 用当前代码构建正常版本，安装到 /Applications 并启动
#   3. 在 localhost:8765 起一个限速的小服务器（看得到进度条），提供 release.json 和 islet.zip
#   4. 让 islet 改查这个地址：设置 →「关于」点「检查更新」，或等启动 30 秒后的自动检查弹窗
# 测完 /Applications 里是那个 +.1 版本；正式版发布后版本号更大，照常能更新回去。
set -euo pipefail
cd -- "${0:A:h}"

plist=Resources/Info.plist
current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $plist)
next="$current.1"
dir=$(mktemp -d)
domain=local.codex.islet

# 1. 新版：临时改版本号构建，构建完立刻改回
cp $plist "$dir/Info.plist.bak"
trap 'cp "$dir/Info.plist.bak" $plist' EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" $plist
build() { ./build.sh "$@" >"$dir/build.log" 2>&1 || { grep -E "error" "$dir/build.log"; echo "构建失败，完整输出：$dir/build.log"; exit 1; } }   # 只在失败时显示输出
build
cp "$dir/Info.plist.bak" $plist
ditto -c -k --keepParent build/islet.app "$dir/islet.zip"
size=$(stat -f %z "$dir/islet.zip")
sha=$(shasum -a 256 "$dir/islet.zip" | cut -d' ' -f1)
cat > "$dir/release.json" <<EOF
{
  "tag_name": "v$next",
  "html_url": "https://github.com/Buerxzhang/islet/releases",
  "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "body": "## 改进\n\n- 这是本地测试用的更新说明，第一条。\n- 第二条：说明比较长的时候会自动换行，看看对齐是否正常，左边的圆点要和第一行文字对齐。\n- 第三条。\n\n## 调整\n\n- 第四条。\n\n## 升级\n\n- 这一节不应该出现在弹窗里。",
  "assets": [{ "name": "islet.zip", "size": $size, "digest": "sha256:$sha",
               "browser_download_url": "http://localhost:8765/islet.zip" }]
}
EOF
echo "新版 $next 已打包：$dir/islet.zip（$((size / 1024)) KB）"

# 2. 安装当前版本
build install
echo "已安装：/Applications/islet.app（$current）"

# 3. 让 islet 查本地地址，清掉“已检查 / 已弹过 / 已跳过”的记录
defaults write $domain updateFeedURL http://localhost:8765/release.json
defaults delete $domain lastUpdateCheck 2>/dev/null || true
defaults delete $domain notifiedUpdateVersion 2>/dev/null || true
defaults delete $domain skippedUpdateVersion 2>/dev/null || true
# 版本号在第 1 步已经改回，这里只恢复查 GitHub（再还原 Info.plist 会覆盖测试期间改过的版本号）
trap 'defaults delete $domain updateFeedURL 2>/dev/null; echo "\n已恢复为查 GitHub"' EXIT INT

# 重新启动一次，让 islet 读到新地址（启动 30 秒后自动检查并弹窗）
pkill -x islet 2>/dev/null && sleep 0.5; open /Applications/islet.app
echo "服务器：http://localhost:8765/release.json（约 30 秒后自动弹窗，或在设置 →「关于」点「检查更新」）"
echo "Ctrl-C 结束"

# 4. 限速服务器：每 0.1 秒发 64 KB，下载过程大约持续几秒
python3 -I - "$dir" <<'PY'
import http.server, os, sys, time
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(root, os.path.basename(self.path))
        if not os.path.isfile(path): self.send_error(404); return
        data = open(path, 'rb').read()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        for i in range(0, len(data), 65536):
            self.wfile.write(data[i:i + 65536])
            if path.endswith('.zip'): time.sleep(0.1)
http.server.ThreadingHTTPServer(('127.0.0.1', 8765), H).serve_forever()
PY
