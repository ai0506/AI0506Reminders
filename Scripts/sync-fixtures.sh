#!/bin/bash
# 从 Calendar 拉取共用假数据。
#
# 权威副本在 Calendar 仓库（数据模型是它的），Reminders 只是消费者；
# 这里存的是 vendored 副本，因为两个项目是各自独立的 git 仓库。
# 改假数据请改 Calendar 那份，然后跑这个脚本。
set -euo pipefail

CALENDAR="${CALENDAR_REPO:-$(cd "$(dirname "$0")/../../Calendar" && pwd)}"
SOURCE="$CALENDAR/fixtures/sample-workspace.json"
TARGET="$(cd "$(dirname "$0")/.." && pwd)/Reminders/Resources/sample-workspace.json"

if [ ! -f "$SOURCE" ]; then
  echo "找不到 $SOURCE" >&2
  echo "设 CALENDAR_REPO 指向 Calendar 仓库根目录，或把它 clone 到 Reminders 的同级目录。" >&2
  exit 1
fi

if diff -q "$SOURCE" "$TARGET" >/dev/null 2>&1; then
  echo "已是最新：$TARGET"
else
  cp "$SOURCE" "$TARGET"
  echo "已更新：$TARGET"
  echo "记得把它和相关改动一起提交。"
fi
