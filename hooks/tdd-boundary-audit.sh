#!/bin/bash
# =============================================================================
# tdd-boundary-audit.sh  —  SubagentStart / SubagentStop フック（matcher: test-writer|implementer）
#
# tdd-boundary-guard.sh はコマンド単位のヒューリスティックなので、python/node のワンライナーなど取りこぼしがある。
# こちらは「成果物」で判定する第 2 の防衛線:
#   SubagentStart: HEAD と、その時点で既に変更されていたファイル一覧を記録する
#   SubagentStop : 起動後に変更されたファイル（コミット済み + 作業ツリー）を集め、役割の境界を越えたものがあれば
#                  停止を 1 回だけ差し止め（exit 2）、報告に「BOUNDARY VIOLATION: <files>」の行を入れさせる。
#                  修正・巻き戻しはさせない（そのための git 操作もガードで止まるため）。呼び出し元が復元する。
#                  2 回目（stop_hook_active=true）は無限ループを避けて通す。
#                  記録は違反が解消されるまで残るので、呼び出し元が復元してから再開・停止すればクリーンに通る。
#
# git リポジトリでない場合、jq が無い場合は何もしない。
# =============================================================================
set -u
set -f

DEFAULT_TEST_PATTERNS='*/test/* */tests/* */__tests__/* */__mocks__/* */__snapshots__/* */__fixtures__/* */testdata/* *.test.* *.spec.* *_test.go *_test.py */test_*.py *Test.java *Tests.java *IT.java *Test.kt *Test.cs *Tests.cs *_spec.rb *_test.rb *.feature *.snap */conftest.py'
TEST_PATTERNS="${CLAUDE_PLUGIN_OPTION_TEST_PATH_PATTERNS:-${TDD_TEST_PATTERNS:-$DEFAULT_TEST_PATTERNS}}"

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty')
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty'); session_id="${session_id:-nosession}"
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

case "${agent_type##*:}" in
  test-writer) role=test ;;
  implementer) role=impl ;;
  *) exit 0 ;;
esac
[ -n "$agent_id" ] || exit 0

if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || exit 0; fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

state_dir="${TMPDIR:-/tmp}/claude-tdd-guard"
mkdir -p "$state_dir" 2>/dev/null || exit 0
state="$state_dir/$(printf '%s' "${session_id}-${agent_id}" | tr -c 'A-Za-z0-9_.\n-' '_')"

is_test_path() {
  local p="/${1}" pat
  for pat in $TEST_PATTERNS; do
    case "$p" in $pat) return 0 ;; esac
  done
  return 1
}

dirty_files() {  # 作業ツリーで変更・追加・削除・未追跡のファイル（リネームは新旧両方）
  git status --porcelain --untracked-files=all 2>/dev/null | cut -c4- \
    | awk '{ if (match($0, / -> /)) { print substr($0, 1, RSTART-1); print substr($0, RSTART+4) } else print }'
}

case "$event" in
  SubagentStart)
    { git rev-parse HEAD 2>/dev/null || echo NOHEAD; dirty_files; } > "$state" 2>/dev/null
    exit 0 ;;
  SubagentStop) ;;
  *) exit 0 ;;
esac

[ -f "$state" ] || exit 0
start_head=$(head -n 1 "$state")
baseline=$(tail -n +2 "$state")

changed=$( {
  if [ "$start_head" != "NOHEAD" ] && git cat-file -e "$start_head" 2>/dev/null; then
    git diff --name-only "$start_head" HEAD 2>/dev/null
  fi
  dirty_files
} | sed '/^$/d' | sort -u )

violations=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # 起動前から変更されていたファイルは除外
  if printf '%s\n' "$baseline" | grep -Fxq -- "$f"; then continue; fi
  if [ "$role" = test ]; then
    is_test_path "$f" || violations="${violations}${f}"$'\n'
  else
    is_test_path "$f" && violations="${violations}${f}"$'\n'
  fi
done <<< "$changed"

if [ -z "$violations" ]; then
  rm -f "$state"      # 違反なし: 記録を消して通す
  exit 0
fi
# 違反あり: 記録は残す。呼び出し元がファイルを復元した後に再開・停止すれば、その時点で差分が消えて通る

stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // empty')
if [ "$stop_hook_active" = "true" ]; then
  # 2 回目: ループを避けて通す（トランスクリプトには残す）
  printf '[tdd-boundary-audit] 境界を越えた変更が残っています（申告済みとして通します）:\n%s' "$violations"
  exit 0
fi

if [ "$role" = test ]; then who="test-writer はテストファイル以外を変更してはいけません"; else who="implementer はテストファイルを変更してはいけません"; fi
cat >&2 <<MSG
[tdd-boundary-audit] ${who}が、この起動中に次のファイルが変更されています:
${violations}
これらを自分で直したり巻き戻したりしないでください（そのための git 操作はガードで止まります）。
代わりに、報告の末尾に次の 1 行を必ず入れ、どの操作で変わったかを説明してから終了してください:
BOUNDARY VIOLATION: $(printf '%s' "$violations" | tr '\n' ' ')
呼び出し元がこれらのファイルを起動前の状態に復元します。
MSG
exit 2
