#!/bin/bash
# =============================================================================
# main-edit-guard.sh  —  PreToolUse フック（matcher: Write|Edit|NotebookEdit）【フォーク版】
#
# メイン会話での「実装」を implementer(sonnet) / code-writer(haiku) に押し出す。
#
# 2 段階の強さを userConfig で切り替える:
#   block_main_edits=false（既定・推奨）: 行数ベース。Write の content または Edit の new_string が
#       main_write_max_lines（既定 40）行を超えたらブロック。小さな修正はメインで許可する。
#       → 1 行の typo 修正のためにサブエージェントを起動する（起動コスト > 修正コスト）事態を避ける。
#   block_main_edits=true: メイン会話のコード変更を全面ブロック。
#       → メインを「計画・委譲・検証だけ」に固定したい場合。/usage で効果を測ってから切り替える。
#
# 常に通すもの:
#   - サブエージェント内の Write/Edit（implementer / code-writer が書く側）
#   - 計画・仕様ドキュメント（*.md、tasks/ spec/ docs/ 配下）。/spec /plan の成果物はメインの担当。
# =============================================================================
set -u

MAX_LINES="${CLAUDE_PLUGIN_OPTION_MAIN_WRITE_MAX_LINES:-40}"
case "$MAX_LINES" in ''|*[!0-9]*) MAX_LINES=40 ;; esac
block_all=$(printf '%s' "${CLAUDE_PLUGIN_OPTION_BLOCK_MAIN_EDITS:-false}" | tr '[:upper:]' '[:lower:]')

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty')
[ -n "$agent_type" ] && exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$path" ] || path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty')

# 計画・仕様ドキュメントはメイン会話の担当なので通す
case "$path" in
  *.md|*.MD|tasks/*|*/tasks/*|spec/*|*/spec/*|docs/*|*/docs/*) exit 0 ;;
esac

case "$block_all" in
  true|1|yes|on)
    cat >&2 <<EOF
[main-edit-guard] メイン会話でのコード変更はブロックされています（block_main_edits=true）。
実装は implementer サブエージェントに「タスク・受け入れ基準・関係するパス」を渡して任せてください。
既存パターンの複製で済むファイル（テスト・設定・型定義・フィクスチャ）は code-writer に spec と参照ファイルと出力先を渡して書かせてください。
同じタスクの続きは新しく起動せず、同じ implementer を再開してください。
EOF
    exit 2 ;;
esac

case "$tool" in
  Write) content=$(printf '%s' "$input" | jq -r '.tool_input.content // empty') ;;
  Edit)  content=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty') ;;
  *)     exit 0 ;;
esac
[ -n "$content" ] || exit 0

lines=$(printf '%s\n' "$content" | wc -l | tr -d '[:space:]')
[ "$lines" -gt "$MAX_LINES" ] 2>/dev/null || exit 0

cat >&2 <<EOF
[main-edit-guard] この ${tool} は ${lines} 行のコードをメイン会話から書き込もうとしています（上限 ${MAX_LINES} 行）。
この規模の実装はメインで行わず、次のどちらかに委譲してください:
  1. ロジックを含む実装 → implementer サブエージェント（タスク・受け入れ基準・関係するパスを渡す）
  2. 既存パターンの複製（テスト・設定・型定義・フィクスチャ）→ code-writer サブエージェント（spec と参照ファイルと出力先を渡す）
上限以下の小さな修正はメインで行って構いません。
EOF
exit 2
