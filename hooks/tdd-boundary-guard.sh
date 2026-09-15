#!/bin/bash
# =============================================================================
# tdd-boundary-guard.sh  —  PreToolUse フック（matcher: Write|Edit|MultiEdit|NotebookEdit|Bash）
#
# TDD の役割分担を強制する:
#   test-writer  … テストファイル「以外」への書き込みを禁止（src にスタブを作るのも不可）
#   implementer  … テストファイル「への」書き込みを禁止（スナップショット更新も不可）
#
# 対象:
#   - Write / Edit / MultiEdit / NotebookEdit の file_path
#   - Bash の書き込み系操作: リダイレクト（> >> 2> &>）、tee、sed -i / perl -i、rm mv cp touch truncate mkdir install ln chmod patch、
#     dd of=、git rm/mv/checkout/restore/switch/add/reset のパス引数
#   - 両ロール共通で禁止: git stash / git clean / git reset --hard / git add -A|--all|. / git commit -a /
#     git checkout . / git apply / git am / git cherry-pick / git revert / git merge / git rebase / git pull
#   - implementer のみ: テストランナーのスナップショット更新フラグ（-u --updateSnapshot --update-snapshots --snapshot-update）
#
# 対象外（通す）: /dev/* /tmp/* /var/tmp/* $TMPDIR 配下への書き込み、読み取り専用コマンド、他のエージェントとメイン会話。
# シェルの完全な解析はしないので、python/node の 1 行スクリプトなどは検出できない。取りこぼしは
# tdd-boundary-audit.sh（SubagentStop）と /build の成果物確認（git show --stat）で捕まえる。
#
# テストファイルの判定パターン（空白区切りの case パターン、先頭に / を付けたパスに対して照合）:
#   CLAUDE_PLUGIN_OPTION_TEST_PATH_PATTERNS → TDD_TEST_PATTERNS → 既定値
# =============================================================================
set -u
set -f

DEFAULT_TEST_PATTERNS='*/test/* */tests/* */__tests__/* */__mocks__/* */__snapshots__/* */__fixtures__/* */testdata/* *.test.* *.spec.* *_test.go *_test.py */test_*.py *Test.java *Tests.java *IT.java *Test.kt *Test.cs *Tests.cs *_spec.rb *_test.rb *.feature *.snap */conftest.py'
TEST_PATTERNS="${CLAUDE_PLUGIN_OPTION_TEST_PATH_PATTERNS:-${TDD_TEST_PATTERNS:-$DEFAULT_TEST_PATTERNS}}"

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty')
case "${agent_type##*:}" in
  test-writer) role=test ;;
  implementer) role=impl ;;
  *) exit 0 ;;
esac

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" 2>/dev/null || true; fi

is_test_path() {
  local p="/${1}" pat
  for pat in $TEST_PATTERNS; do
    case "$p" in $pat) return 0 ;; esac
  done
  return 1
}

proj="${cwd:-$PWD}"; proj="${proj%/}"
is_scratch_path() {  # 一時ファイル・デバイス・fd への書き込みは対象外。ただしプロジェクト配下は常に対象
  local p="$1"
  case "$p" in "&"*|-) return 0 ;; esac
  case "$p" in /*) ;; *) p="$proj/$p" ;; esac
  case "$p" in "$proj"/*) return 1 ;; esac
  case "$p" in
    /dev/*|/tmp/*|/var/tmp/*|/private/tmp/*|"${TMPDIR:-/__none__}"/*) return 0 ;;
  esac
  return 1
}

# この役割にとって書き込み禁止のパスなら 0 を返す
is_forbidden() {
  is_scratch_path "$1" && return 1
  if [ "$role" = test ]; then
    if is_test_path "$1"; then return 1; else return 0; fi
  else
    if is_test_path "$1"; then return 0; else return 1; fi
  fi
}

block_path() {
  if [ "$role" = test ]; then
    cat >&2 <<MSG
[tdd-boundary] test-writer はテストファイル以外に書き込めません: $1
実装コードやスタブを作らず、テストが前提にするモジュール・関数のシグネチャを「契約」として報告してください。
（テストファイルの判定パターンは test_path_patterns で調整できます）
MSG
  else
    cat >&2 <<MSG
[tdd-boundary] implementer はテストファイルを変更できません: $1
テストが間違っている・矛盾していると考える場合は、直さずに「どのテストの何が問題か・根拠（パス:行番号）・提案」を報告して止まってください。
呼び出し元が判断し、必要なら test-writer に修正させてからあなたを再開します。
MSG
  fi
  exit 2
}

block_op() {
  cat >&2 <<MSG
[tdd-boundary] '$1' は作業ツリー全体や相手側のファイルに影響し得るため、この役割（${agent_type}）では使えません。
変更したファイルを明示して 'git add <path>' し、'git commit -m' でコミットしてください。$2
MSG
  exit 2
}

# ---------------------------------------------------------------- Write / Edit 系
case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit)
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
    [ -n "$path" ] || path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty')
    [ -n "$path" ] || exit 0
    is_forbidden "$path" && block_path "$path"
    exit 0 ;;
  Bash) ;;
  *) exit 0 ;;
esac

# ---------------------------------------------------------------- Bash
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

strip_quotes() { printf '%s' "$1" | tr -d '"'"'"'`'; }

check_target() {  # $1: 書き込み先候補
  local t
  t=$(strip_quotes "$1")
  [ -n "$t" ] || return 0
  is_forbidden "$t" && block_path "$t"
  return 0
}

# パイプ・連結・改行でセグメントに分割（bash の置換だけを使い、BSD sed 依存を避ける）
segments=$cmd
segments=${segments//'&&'/$'\n'}
segments=${segments//'||'/$'\n'}
segments=${segments//';'/$'\n'}
segments=${segments//'|'/$'\n'}

# 注意: パイプで while に渡すとサブシェルになり exit 2 が伝わらないので、ヒアストリングで回す
while IFS= read -r seg; do
  # リダイレクト記号を独立トークン __REDIR__ にする（2>、&>、>> も含む）
  seg=$(printf '%s' "$seg" | sed -E 's/[0-9]*>>?/ __REDIR__ /g; s/&>>?/ __REDIR__ /g')
  # shellcheck disable=SC2086
  set -- $seg
  [ $# -gt 0 ] || continue

  # 先頭の環境変数代入や sudo/env/time などを飛ばして実コマンドを得る
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;
      sudo|env|time|command|nohup|nice|exec) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || continue
  name=$(basename -- "$1"); shift

  # 1) リダイレクト先はコマンドを問わず書き込み先
  prev=""
  for tok in "$@"; do
    [ "$prev" = "__REDIR__" ] && check_target "$tok"
    prev="$tok"
  done

  # 2) コマンド別
  case "$name" in
    git)
      sub=""; for tok in "$@"; do case "$tok" in -*) ;; *) sub="$tok"; break ;; esac; done
      case "$sub" in
        stash|clean|apply|am|cherry-pick|revert|merge|rebase|pull)
          block_op "git $sub" "" ;;
        reset)
          for tok in "$@"; do [ "$tok" = "--hard" ] && block_op "git reset --hard" ""; done
          for tok in "$@"; do case "$tok" in -*|reset|HEAD*) ;; *) check_target "$tok" ;; esac; done ;;
        add)
          for tok in "$@"; do case "$tok" in -A|--all|.) block_op "git add $tok" " ステージするファイルは個別に指定します。" ;; esac; done
          for tok in "$@"; do case "$tok" in -*|add) ;; *) check_target "$tok" ;; esac; done ;;
        commit)
          for tok in "$@"; do case "$tok" in --all|-a|-a[!-]*) block_op "git commit $tok" " -a は相手側の変更まで巻き込みます。" ;; esac; done ;;
        checkout|switch)
          for tok in "$@"; do [ "$tok" = "." ] && block_op "git $sub ." ""; done
          after_dd=0
          for tok in "$@"; do
            if [ "$tok" = "--" ]; then after_dd=1; continue; fi
            case "$tok" in -*|checkout|switch) continue ;; esac
            t=$(strip_quotes "$tok")
            if [ "$after_dd" = 1 ] || [ -e "$t" ]; then check_target "$t"; fi
          done ;;
        restore|rm|mv)
          for tok in "$@"; do case "$tok" in -*|restore|rm|mv|--) ;; *) check_target "$tok" ;; esac; done ;;
      esac ;;
    rm|mv|cp|touch|truncate|mkdir|rmdir|install|ln|chmod|chown|tee|patch)
      for tok in "$@"; do case "$tok" in -*) ;; *) check_target "$tok" ;; esac; done ;;
    sed|perl|ruby)
      inplace=0
      for tok in "$@"; do case "$tok" in -i*|--in-place*) inplace=1 ;; esac; done
      if [ "$inplace" = 1 ]; then
        for tok in "$@"; do
          case "$tok" in -*) ;; *) t=$(strip_quotes "$tok"); [ -e "$t" ] && check_target "$t" ;; esac
        done
      fi ;;
    dd)
      for tok in "$@"; do case "$tok" in of=*) check_target "${tok#of=}" ;; esac; done ;;
  esac

  # 3) implementer のスナップショット更新
  if [ "$role" = impl ]; then
    case "$name $*" in
      *jest*|*vitest*|*pytest*|*"npm test"*|*"npm run test"*|*"pnpm test"*|*"yarn test"*|*mocha*|*" ava"*|*"go test"*)
        for tok in "$@"; do
          case "$tok" in
            -u|--updateSnapshot|--update-snapshots|--snapshot-update|--update-snapshot|-u=*)
              block_op "スナップショット更新 ($tok)" " スナップショットはテスト側の資産です。実装が正しいと考える場合は報告して止まってください。" ;;
          esac
        done ;;
    esac
  fi
done <<< "$segments"

exit 0
