#!/bin/bash
# =============================================================================
# big-bash-read-guard.sh  —  PreToolUse フック（matcher: Bash）【フォーク版 v2】
#
# Read ガードを迂回して `cat file` 等で大きなファイルを丸読みする操作を検出する。
# 除外ルールとしきい値は big-read-guard.sh と同じ（許可リストのエージェントだけ通す）。
#
# 単一コマンドを対象にした軽量なヒューリスティック（パイプ・リダイレクト・連結があれば通す）。
# 主防衛線は big-read-guard.sh。
# =============================================================================
set -u
set -f

UNGUARDED_AGENTS="bulk-reader code-writer Explore Plan"

MIN_LINES="${CLAUDE_PLUGIN_OPTION_MIN_LINES:-${BULK_READ_MIN_LINES:-350}}"
case "$MIN_LINES" in ''|*[!0-9]*) MIN_LINES=350 ;; esac

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty')
agent_base="${agent_type##*:}"
for a in $UNGUARDED_AGENTS; do
  [ "$agent_base" = "$a" ] && exit 0
done

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *'|'*|*'>'*|*'<'*|*'&&'*|*';'*) exit 0 ;;
esac

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  cd "$cwd" || exit 0
fi

# shellcheck disable=SC2086
set -- $cmd
[ $# -gt 0 ] || exit 0
case "$1" in
  cat|less|more) ;;
  *) exit 0 ;;
esac
shift

total=0
files=""
for arg in "$@"; do
  case "$arg" in -*) continue ;; esac
  [ -f "$arg" ] || continue
  n=$(wc -l < "$arg" | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) continue ;; esac
  total=$((total + n))
  files="${files} ${arg}"
done

[ "$total" -gt "$MIN_LINES" ] || exit 0

cat >&2 <<EOF
[big-bash-read-guard] このコマンドは${files} の合計 ${total} 行（しきい値 ${MIN_LINES} 行）をそのままコンテキストに読み込みます。
代わりに次のいずれかを行ってください:
  1. 内容を理解したいだけなら、bulk-reader サブエージェントにファイルパスと知りたいことを渡す。
  2. 必要な範囲が分かっているなら、grep や sed -n 'START,ENDp' で絞り込む。
EOF
exit 2
