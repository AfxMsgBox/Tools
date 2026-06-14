#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  ./git-pull.sh <git地址> <分支名> <项目子目录> [本地目录]

说明:
  将指定 Git 仓库某个分支中的项目子目录（包含其所有子目录和文件）下载到本地目录。
  如果不指定 [本地目录]，默认下载到当前目录。

参数:
  <git地址>      Git 仓库地址，例如 https://github.com/user/repo.git 或 git@github.com:user/repo.git
  <分支名>       要下载的分支名，例如 main
  <项目子目录>   仓库中的子目录路径，例如 scripts/tools
  [本地目录]     可选，本地保存目录，默认是当前目录

示例:
  ./git-pull.sh https://github.com/user/repo.git main scripts/tools ./tools
USAGE
}

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

GIT_URL="$1"
BRANCH_NAME="$2"
PROJECT_SUBDIR="$3"
LOCAL_DIR="${4:-.}"

if [[ -z "$GIT_URL" || -z "$BRANCH_NAME" || -z "$PROJECT_SUBDIR" || -z "$LOCAL_DIR" ]]; then
  echo "错误: 参数不能为空。" >&2
  usage >&2
  exit 1
fi

if [[ "$PROJECT_SUBDIR" = /* || "$PROJECT_SUBDIR" == *".."* ]]; then
  echo "错误: <项目子目录> 必须是仓库内的相对路径，且不能包含 '..'。" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "错误: 未找到 git，请先安装 git。" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
REPO_DIR="$TMP_DIR/repo"

mkdir -p "$LOCAL_DIR"

printf "正在从仓库下载指定目录...\n"
printf "Git 地址: %s\n" "$GIT_URL"
printf "分支: %s\n" "$BRANCH_NAME"
printf "项目子目录: %s\n" "$PROJECT_SUBDIR"
printf "本地目录: %s\n" "$LOCAL_DIR"

# 使用浅克隆 + sparse-checkout，只拉取指定目录，避免下载整个工作区。
git clone \
  --depth 1 \
  --branch "$BRANCH_NAME" \
  --single-branch \
  --filter=blob:none \
  --sparse \
  "$GIT_URL" \
  "$REPO_DIR"

(
  cd "$REPO_DIR"
  git sparse-checkout set --no-cone "$PROJECT_SUBDIR"
)

SOURCE_DIR="$REPO_DIR/$PROJECT_SUBDIR"
if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "错误: 仓库分支中不存在目录: $PROJECT_SUBDIR" >&2
  exit 1
fi

# 复制目录内容（包含隐藏文件）到目标目录，而不是额外嵌套一层项目子目录。
cp -a "$SOURCE_DIR"/. "$LOCAL_DIR"/

printf "下载完成: %s -> %s\n" "$PROJECT_SUBDIR" "$LOCAL_DIR"
