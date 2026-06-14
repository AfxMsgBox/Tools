#!/usr/bin/env bash
set -euo pipefail

GIT_URL="${1:-}"
BRANCH="${2:-}"
REMOTE_DIR="${3:-}"
LOCAL_DIR="${4:-.}"

if [ -z "$GIT_URL" ] || [ -z "$BRANCH" ] || [ -z "$REMOTE_DIR" ]; then
    echo "用法:"
    echo "  $0 <git地址> <分支名> <远程父目录> [本地目录]"
    echo
    echo "说明:"
    echo "  拉取 <远程父目录> 下的所有直接子目录到 [本地目录]。"
    echo "  子目录内的文件会一并保留；<远程父目录> 根层级的文件不会单独拉取。"
    echo
    echo "示例:"
    echo "  $0 https://github.com/openwrt/openwrt.git main package/network/services ./services"
    echo "  $0 git@github.com:user/repo.git dev path/to/dir"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "错误: 未安装 git"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$LOCAL_DIR"
LOCAL_DIR_ABS="$(cd "$LOCAL_DIR" && pwd)"

echo "Git 地址: $GIT_URL"
echo "分支: $BRANCH"
echo "远程父目录: $REMOTE_DIR"
echo "本地目录: $LOCAL_DIR_ABS"
echo

cd "$TMP_DIR"

git init -q
git remote add origin "$GIT_URL"

git sparse-checkout init --cone
git sparse-checkout set "$REMOTE_DIR"

git pull --depth=1 origin "$BRANCH"

if [ ! -d "$REMOTE_DIR" ]; then
    echo "错误: 远程目录不存在: $REMOTE_DIR"
    exit 1
fi

copied_count=0

# 复制指定目录下的所有直接子目录（包含隐藏目录），并保留目录内部内容。
while IFS= read -r -d '' subdir; do
    cp -a "$subdir" "$LOCAL_DIR_ABS"/
    copied_count=$((copied_count + 1))
done < <(find "$REMOTE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

if [ "$copied_count" -eq 0 ]; then
    echo "警告: $REMOTE_DIR 下没有可复制的子目录"
else
    echo
    echo "完成: 已将 $REMOTE_DIR 下的 $copied_count 个子目录拉取到 $LOCAL_DIR_ABS"
fi
