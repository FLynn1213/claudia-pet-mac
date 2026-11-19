#!/bin/sh
# 卸载 mac 版（对应 Windows 版 scripts/uninstall.ps1）：撤销接入、退出、删掉 ~/.local/bin/claudia-pet 和编译结果，默认连数据一起删
#   sh mac/uninstall.sh [--keep-data]
# 仓库本身不删；不想要了自己删掉这个文件夹就行
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
KEEP=0
for a in "$@"; do
  case "$a" in
    --keep-data) KEEP=1 ;;
    *) echo "不认识的参数：$a" >&2; exit 2 ;;
  esac
done

# 撤销 Claude Code 插件和桌面端（MCP）的接入（改之前会备份配置）
if [ -x "$HERE/build/claudia-pet" ]; then
  "$HERE/build/claudia-pet" --disconnect all || echo "（撤销接入失败，可以之后在 Claude 的配置里手动删掉 claudia-pet）"
else
  echo "（没找到编译结果，跳过撤销接入；如果接入过，请先 sh mac/build.sh 再卸载）"
fi

pkill -f 'claudia-pet.app/Contents/MacOS/claudia-pet' 2>/dev/null && echo "已退出 claudia-pet" || true

LINK="$HOME/.local/bin/claudia-pet"
if [ -L "$LINK" ]; then rm -f "$LINK" && echo "已删除 $LINK"; fi
rm -rf "$HERE/build" && echo "已删除编译结果 mac/build"

if [ "$KEEP" = 1 ]; then
  echo "保留了设置和数据：~/.claudia"
else
  rm -rf "$HOME/.claudia" && echo "已删除设置和数据：~/.claudia"
fi

echo "如果给过辅助功能权限（聊天模式动画），可以在「系统设置 → 隐私与安全性 → 辅助功能」里删掉 claudia-pet，或运行：tccutil reset Accessibility io.github.claudia-pet"
