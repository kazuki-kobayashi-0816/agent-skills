#!/bin/bash
# =============================================================================
# big-read-guard.sh  —  PreToolUse フック（matcher: Read）【フォーク版 v2】
#
# 大きなファイルの Read を止め、bulk-reader への委譲か offset/limit の範囲読み込みに誘導する。
#
# v1 との違い: 除外を「サブエージェントなら全部通す」から「許可リストのエージェントだけ通す」に変更。
#   通す  : bulk-reader / code-writer / Explore / Plan（安いモデルで I/O を引き受ける側）
#   止める: メイン会話、codebase-analyst(opus)、implementer(sonnet)、agent-skills のペルソナ
#   → 「大きなファイルを丸読みしてよいのは安いモデルだけ」という原則をどの層でも強制する。
#
# しきい値の優先順位: CLAUDE_PLUGIN_OPTION_MIN_LINES → BULK_READ_MIN_LINES → 350
# =============================================================================
set -u

UNGUARDED_AGENTS="bulk-reader code-writer Explore Plan"

MIN_LINES="${CLAUDE_PLUGIN_OPTION_MIN_LINES:-${BULK_READ_MIN_LINES:-350}}"
case "$MIN_LINES" in ''|*[!0-9]*) MIN_LINES=350 ;; esac

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

# agent_type はプラグイン経由だと "agent-skills:bulk-reader" のように名前空間付きになるので、末尾で判定する
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty')
agent_base="${agent_type##*:}"
for a in $UNGUARDED_AGENTS; do
  [ "$agent_base" = "$a" ] && exit 0
done

offset=$(printf '%s' "$input" | jq -r '.tool_input.offset // empty')
limit=$(printf '%s' "$input" | jq -r '.tool_input.limit // empty')
if [ -n "$offset" ] || [ -n "$limit" ]; then
  exit 0
fi

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$path" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  cd "$cwd" || exit 0
fi
[ -f "$path" ] || exit 0

case "$path" in
  *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.svg|*.pdf) exit 0 ;;
esac

lines=$(wc -l < "$path" | tr -d '[:space:]')
[ "$lines" -gt "$MIN_LINES" ] 2>/dev/null || exit 0

where="メイン会話"
[ -n "$agent_type" ] && where="サブエージェント ${agent_type}"

cat >&2 <<EOF
[big-read-guard] ${path} は ${lines} 行あり、しきい値（${MIN_LINES} 行）を超えています（${where} からの Read）。
このファイルを直接 Read しないでください。代わりに次のいずれかを行ってください:
  1. 内容を理解したいだけなら、bulk-reader サブエージェントに「ファイルパス」と「知りたいこと」を渡し、要約だけ受け取る。
  2. 編集のために特定箇所の正確な内容が必要なら、Grep で位置を特定し、offset と limit を指定してその範囲だけ Read する。
EOF
exit 2
