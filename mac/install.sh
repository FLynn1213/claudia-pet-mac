#!/bin/sh
# 编译并装到 ~/.local/bin/claudia-pet（符号链接，指向这个仓库里的编译结果；仓库不要再挪位置）
#   sh mac/install.sh [--connect] [--no-start]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
CONNECT=0; START=1
for a in "$@"; do
  case "$a" in
    --connect) CONNECT=1 ;;
    --no-start) START=0 ;;
    *) echo "不认识的参数：$a" >&2; exit 2 ;;
  esac
done
command -v swiftc >/dev/null 2>&1 || { echo "没有 swiftc：先运行 xcode-select --install 装命令行工具" >&2; exit 1; }
sh "$HERE/build.sh"
mkdir -p "$HOME/.local/bin"
ln -sf "$HERE/build/claudia-pet" "$HOME/.local/bin/claudia-pet"
echo "已装：~/.local/bin/claudia-pet"
[ "$CONNECT" = 1 ] && "$HERE/build/claudia-pet" --connect all
if [ "$START" = 1 ]; then
  nohup "$HERE/build/claudia-pet" >/dev/null 2>&1 &
  echo "已启动。日志：~/.claudia/mac.log"
fi
