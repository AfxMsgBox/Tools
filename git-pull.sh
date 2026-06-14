#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  ./git-pull.sh <git地址> <分支名> <项目子目录> [本地目录]

说明:
  将指定 Git 仓库某个分支中的项目子目录（包含其所有子目录和文件）下载到本地目录。
  如果 <项目子目录> 传 . 或 /，则下载该分支的整个仓库工作区（不包含 .git 目录）。
  如果不指定 [本地目录]，默认下载到当前目录。

参数:
  <git地址>      Git 仓库地址，例如 https://github.com/user/repo.git 或 git@github.com:user/repo.git
  <分支名>       要下载的分支名，例如 main
  <项目子目录>   仓库中的子目录路径，例如 scripts/tools
  [本地目录]     可选，本地保存目录，默认是当前目录

示例:
  # 下载指定子目录
  ./git-pull.sh https://github.com/user/repo.git main scripts/tools ./tools

  # 下载整个仓库工作区
  ./git-pull.sh https://github.com/user/repo.git main . ./repo-files
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

IS_WHOLE_REPO=0
if [[ "$PROJECT_SUBDIR" == "." || "$PROJECT_SUBDIR" == "./" || "$PROJECT_SUBDIR" == "/" ]]; then
  IS_WHOLE_REPO=1
  PROJECT_SUBDIR="."
else
  # 仅去掉开头的 ./ 和结尾的 /，保留仓库内的相对路径写法。
  while [[ "$PROJECT_SUBDIR" == ./* ]]; do
    PROJECT_SUBDIR="${PROJECT_SUBDIR#./}"
  done
  while [[ "$PROJECT_SUBDIR" == */ ]]; do
    PROJECT_SUBDIR="${PROJECT_SUBDIR%/}"
  done

  if [[ -z "$PROJECT_SUBDIR" || "$PROJECT_SUBDIR" = /* || "$PROJECT_SUBDIR" == ".." || "$PROJECT_SUBDIR" == ../* || "$PROJECT_SUBDIR" == */.. || "$PROJECT_SUBDIR" == */../* ]]; then
    echo "错误: <项目子目录> 必须是仓库内的相对路径，且不能包含 '..' 路径段。" >&2
    exit 1
  fi
fi

if ! command -v git >/dev/null 2>&1; then
  echo "错误: 未找到 git，请先安装 git。" >&2
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "错误: 未找到 tar，请先安装 tar。" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
REPO_DIR="$TMP_DIR/repo"

mkdir -p "$LOCAL_DIR"

if [[ "$IS_WHOLE_REPO" -eq 1 ]]; then
  printf "正在从仓库下载整个工作区...\n"
else
  printf "正在从仓库下载指定目录...\n"
fi
printf "Git 地址: %s\n" "$GIT_URL"
printf "分支: %s\n" "$BRANCH_NAME"
printf "项目子目录: %s\n" "$PROJECT_SUBDIR"
printf "本地目录: %s\n" "$LOCAL_DIR"

if [[ "$IS_WHOLE_REPO" -eq 1 ]]; then
  # 下载整个分支工作区；保留浅克隆和 blob 过滤，但不启用 sparse-checkout。
  git clone \
    --depth 1 \
    --branch "$BRANCH_NAME" \
    --single-branch \
    --filter=blob:none \
    "$GIT_URL" \
    "$REPO_DIR"

  # 复制整个工作区内容，但不把临时仓库的 .git 元数据复制到目标目录。
  tar --exclude='./.git' -cf - -C "$REPO_DIR" . | tar -xf - -C "$LOCAL_DIR"
else
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
fi

if [[ "$IS_WHOLE_REPO" -eq 1 ]]; then
  printf "下载完成: 整个工作区 -> %s\n" "$LOCAL_DIR"
else
  printf "下载完成: %s -> %s\n" "$PROJECT_SUBDIR" "$LOCAL_DIR"
fi
