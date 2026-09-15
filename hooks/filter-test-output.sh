#!/bin/bash
# =============================================================================
# filter-test-output.sh  —  PreToolUse フック（matcher: Bash）【任意】
#
# テストコマンドの出力を「失敗箇所（前後5行）+ 末尾8行 + 終了コード」だけに書き換える。
# 公式ドキュメント（Manage costs effectively）の例をベースに、全件成功時にも結果が分かるよう
# 末尾数行と終了コードを残し、元のコマンドの終了コードを維持する形にしている。
#
# 注意:
#   - updatedInput でコマンドを書き換えるため permissionDecision: allow を返す
#     （= 該当するテストコマンドは権限確認なしで実行される）。
#   - 既にパイプを含むコマンドは触らない。
#   - 有効化するには settings.json の PreToolUse（matcher: Bash）の hooks 配列にこのスクリプトを追加する。
# =============================================================================
set -u
input=$(cat)
command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

is_test=0
case "$cmd" in
  "npm test"*|"npm run test"*|"pnpm test"*|"yarn test"*|"npx vitest"*|"npx jest"*|\
  "pytest"*|"python -m pytest"*|"go test"*|"cargo test"*|\
  "bundle exec rspec"*|"rspec"*|"mvn test"*|"./gradlew test"*|"gradle test"*)
    is_test=1 ;;
esac

if [ "$is_test" -eq 1 ] && [ "${cmd#*|}" = "$cmd" ]; then
  # 失敗行(+後続5行)を最大100行、末尾8行、終了コードを出力。元の終了コードで終了する。
  filtered='__out=$(mktemp); '"$cmd"' >"$__out" 2>&1; __rc=$?; '\
'grep -n -A 5 -E "(FAIL|FAILED|ERROR|Error|error\[|panic:|Traceback|✗|✕|×)" "$__out" | head -n 100; '\
'echo "--- tail ---"; tail -n 8 "$__out"; echo "exit code: $__rc"; rm -f "$__out"; exit $__rc'
  printf '%s' "$input" | jq --arg f "$filtered" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: (.tool_input + {command: $f})}}'
else
  echo '{}'
fi
