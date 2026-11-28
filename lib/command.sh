#!/usr/bin/env bash
# Split a Bash tool command into simple commands for the PreToolUse hooks.
# Sourced, never executed. Works on bash 3.2.
#
# shepherd_split_command CMD fills SHEPHERD_SEGMENTS with one entry per simple
# command: its words, quotes removed, joined by $SHEPHERD_SEP. A segment ends at
# a newline, `;`, `&`, `|`, `(`, or `)`; the body of `$(...)` or backticks is a
# segment of its own. Leading `command`, `env`, `VAR=val`, `sudo`, and `time`
# are dropped, and the script of `bash|sh|zsh|dash|ksh -c` is split in turn.
# An unquoted brace word (`{a,b}`, `{x..y}`) is expanded as bash does; one that
# would make more than 1024 words, or has a step, stays literal and sets
# SHEPHERD_SPLIT_TRUNCATED. SHEPHERD_SEGMENT_SUBST has, per segment, one 0/1
# per word joined by $SHEPHERD_SEP: 1 when the word held a `$(...)`, backticks,
# or `$'...'` / `$"..."`, so its text is not what bash passes. A `$(...)` that is
# a word of its own marks every word of its segment.
# It reads command shapes, not full shell syntax: heredoc bodies and arithmetic
# read as commands, which errs toward a deny.
#
# shepherd_split_command CMD --heredoc-data reads heredocs instead: a body fed
# to a line that runs a shell (bash, sh, zsh, dash, ksh, eval, source, .) is
# split as commands, an unquoted body only for its `$(...)` and backticks, and
# a quoted body (<<'EOF') not at all.

SHEPHERD_SEP=$'\x1f'
SHEPHERD_SPLIT_DEPTH=4

shepherd_split_command() {
  SHEPHERD_SEGMENTS=()
  SHEPHERD_SEGMENT_SUBST=()
  SHEPHERD_SPLIT_TRUNCATED=0
  SHEPHERD_SPLIT_HEREDOC=""
  [[ "${2:-}" == --heredoc-data ]] && SHEPHERD_SPLIT_HEREDOC=data
  local LC_ALL=C
  _shepherd_split "$1" 0
}

_shepherd_split() {
  local s="$1" depth="$2" n=${#1} i=0 c q="" word="" inword=0 line_seg=${#SHEPHERD_SEGMENTS[@]}
  local upos="" uopen=0 udollar=-1 brace=0 wsub=0 segsub=0
  local -a words=() marks=() heredocs=()
  if (( depth > SHEPHERD_SPLIT_DEPTH )); then
    SHEPHERD_SPLIT_TRUNCATED=1
    return 0
  fi
  while (( i < n )); do
    c=${s:i:1}
    if [[ "$q" == "'" ]]; then
      if [[ "$c" == "'" ]]; then q=""; else word+=$c; fi
      i=$((i + 1)); continue
    fi
    if [[ "$c" == '\' ]]; then
      c=${s:i+1:1}
      if [[ "$c" == $'\n' ]]; then
        :
      elif [[ "$q" == '"' && "$c" != [\$\`\"\\] ]]; then
        word+="\\$c"
      else
        word+=$c; inword=1
      fi
      i=$((i + 2)); continue
    fi
    if [[ "$c" == '$' && "${s:i+1:1}" == [\'\"] ]]; then
      i=$((i + 1)); wsub=1; continue
    fi
    _shepherd_substitution && { wsub=1; continue; }
    if [[ "$q" == '"' ]]; then
      if [[ "$c" == '"' ]]; then q=""; else word+=$c; fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      "'" | '"')
        q=$c; inword=1 ;;
      ' ' | $'\t')
        _shepherd_end_word ;;
      $'\n')
        _shepherd_end_segment
        (( ${#heredocs[@]} )) && _shepherd_heredoc_bodies
        line_seg=${#SHEPHERD_SEGMENTS[@]} ;;
      ';' | '|' | '(' | ')')
        _shepherd_end_segment ;;
      '<')
        if [[ "${s:i:3}" == '<<<' ]]; then
          word+='<<<'; inword=1; i=$((i + 2))
        elif [[ "$SHEPHERD_SPLIT_HEREDOC" == data && "${s:i+1:1}" == '<' ]]; then
          _shepherd_end_word
          _shepherd_heredoc_start
          continue
        else
          word+=$c; inword=1
        fi ;;
      '&')
        if (( i > 0 )) && [[ "${s:i-1:1}" == [\<\>] || "${s:i+1:1}" == '>' ]]; then
          word+=$c; inword=1
        else
          _shepherd_end_segment
        fi ;;
      '#')
        if (( inword )); then
          word+=$c
        else
          while (( i + 1 < n )) && [[ "${s:i+1:1}" != $'\n' ]]; do i=$((i + 1)); done
        fi ;;
      *)
        if [[ "$c" == [A-Za-z0-9_,.-] ]] || [[ "$c" == "{" && "$udollar" != "${#word}" ]]; then
          upos+=" ${#word} "
          [[ "$c" == '{' ]] && uopen=1
        elif [[ "$c" == '}' ]]; then
          upos+=" ${#word} "
          (( uopen )) && brace=1
        fi
        [[ "$c" == "$" ]] && udollar=$((${#word} + 1))
        word+=$c; inword=1 ;;
    esac
    i=$((i + 1))
  done
  _shepherd_end_segment
}

# Helpers of _shepherd_split: they read and reset its locals (bash dynamic scope).

# At s[i], split the body of `$(...)` or backticks and move i past it.
# Returns 1 when s[i] starts neither.
_shepherd_substitution() {
  local c=${s:i:1} j level sq=""
  if [[ "$c" == '$' && "${s:i+1:1}" == '(' ]]; then
    j=$((i + 2)); level=1
    while (( j < n && level > 0 )); do
      c=${s:j:1}
      if [[ "$sq" == "'" ]]; then
        [[ "$c" == "'" ]] && sq=""
      elif [[ "$c" == '\' ]]; then
        j=$((j + 1))
      elif [[ "$sq" == '"' ]]; then
        [[ "$c" == '"' ]] && sq=""
      else
        case "$c" in
          "'" | '"') sq=$c ;;
          '(') level=$((level + 1)) ;;
          ')') level=$((level - 1)) ;;
        esac
      fi
      j=$((j + 1))
    done
    _shepherd_split "${s:i+2:j-i-2-(level == 0)}" $((depth + 1))
    i=$j; return 0
  fi
  if [[ "$c" == '`' ]]; then
    j=$((i + 1))
    while (( j < n )) && [[ "${s:j:1}" != '`' ]]; do j=$((j + 1)); done
    _shepherd_split "${s:i+1:j-i-1}" $((depth + 1))
    i=$((j + 1)); return 0
  fi
  return 1
}

# At the `<<` in s[i], record the heredoc as <strip tabs><quoted><delimiter>
# and move i past its delimiter word.
_shepherd_heredoc_start() {
  local strip=0 quoted=0 d="" ch j
  i=$((i + 2))
  [[ "${s:i:1}" == - ]] && { strip=1; i=$((i + 1)); }
  while [[ "${s:i:1}" == [[:blank:]] ]]; do i=$((i + 1)); done
  while (( i < n )); do
    ch=${s:i:1}
    case "$ch" in
      "'" | '"')
        quoted=1; j=$((i + 1))
        while (( j < n )) && [[ "${s:j:1}" != "$ch" ]]; do j=$((j + 1)); done
        d+=${s:i+1:j-i-1}; i=$((j + 1)) ;;
      '\')
        quoted=1; d+=${s:i+1:1}; i=$((i + 2)) ;;
      ' ' | $'\t' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
        break ;;
      *)
        d+=$ch; i=$((i + 1)) ;;
    esac
  done
  heredocs+=("$strip$quoted$d")
}

# At the newline in s[i] that ends a line with heredocs, read their bodies and
# leave i on the newline that ends the last delimiter line. A body with no
# delimiter line (`(( a << 2 ))` reads as a heredoc) stays commands.
_shepherd_heredoc_bodies() {
  local h k line tab body shell=0 found p=$((i + 1))
  for (( k = line_seg; k < ${#SHEPHERD_SEGMENTS[@]}; k++ )); do
    h=${SHEPHERD_SEGMENTS[k]%%"$SHEPHERD_SEP"*}
    case "${h##*/}" in bash | sh | zsh | dash | ksh | eval | source | .) shell=1 ;; esac
  done
  for h in "${heredocs[@]}"; do
    body="" found=0
    while (( p < n )); do
      line=${s:p}; line=${line%%$'\n'*}
      p=$((p + ${#line} + 1))
      tab=$line
      [[ "${h:0:1}" == 1 ]] && while [[ "$tab" == $'\t'* ]]; do tab=${tab#$'\t'}; done
      [[ "$tab" == "${h:2}" ]] && { found=1; break; }
      body+="$line"$'\n'
    done
    if (( ! found )); then
      heredocs=()
      return 0
    elif (( shell )); then
      _shepherd_split "$body" $((depth + 1))
    elif [[ "${h:1:1}" == 0 ]]; then
      _shepherd_substitutions "$body" $((depth + 1))
    fi
  done
  heredocs=()
  i=$((p - 1))
}

# Split only the `$(...)` and backtick bodies of an unquoted heredoc body.
_shepherd_substitutions() {
  local s="$1" depth="$2" n=${#1} i=0
  while (( i < n )); do
    if [[ "${s:i:1}" == '\' ]]; then
      i=$((i + 2))
    elif ! _shepherd_substitution; then
      i=$((i + 1))
    fi
  done
}

_shepherd_end_word() {
  (( ${sub_inherit:-0} )) && wsub=1
  (( wsub && ! inword )) && segsub=1
  if (( inword )); then
    if (( brace )); then
      _shepherd_brace
    else
      words+=("$word"); marks+=("$wsub")
    fi
  fi
  word="" inword=0 upos="" uopen=0 udollar=-1 brace=0 wsub=0
}

# Add the words bash makes of the brace word in `word`. Only the unquoted chars
# in upos stay unescaped, so eval does brace expansion and nothing else.
_shepherd_brace() {
  local e="" k ch len a b total=1 rest
  local re='\{(-?[0-9]+|[A-Za-z])\.\.(-?[0-9]+|[A-Za-z])(\.\.-?[0-9]+)?\}'
  local -a exp=() groups=()
  for (( k = 0; k < ${#word}; k++ )); do
    ch=${word:k:1}
    if [[ "$upos" == *" $k "* ]]; then
      e+=$ch
      case "$ch" in
        '{') groups+=(1) ;;
        ,) (( ${#groups[@]} )) && groups[${#groups[@]} - 1]=$((groups[${#groups[@]} - 1] + 1)) ;;
        '}')
          if (( ${#groups[@]} )); then
            total=$((total * groups[${#groups[@]} - 1]))
            (( total > 1024 )) && total=1025
            unset "groups[${#groups[@]} - 1]"
          fi ;;
      esac
    elif [[ "$ch" == $'\n' ]]; then
      e+="'"$'\n'"'"
    else
      e+="\\$ch"
    fi
  done
  (( total > 1024 )) && total=0
  rest=$e
  while (( total )) && [[ "$rest" =~ $re ]]; do
    a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
    rest=${rest#*"${BASH_REMATCH[0]}"}
    if [[ -n "${BASH_REMATCH[3]}" || ${#a} -gt 5 || ${#b} -gt 5 ]]; then
      total=0
    elif [[ "$a" == *[0-9] && "$b" == *[0-9] ]]; then
      len=$((10#${a#-} * ${a%%[0-9]*}1 - 10#${b#-} * ${b%%[0-9]*}1))
      total=$((total * (${len#-} + 1)))
    elif [[ "$a" == [A-Za-z] && "$b" == [A-Za-z] ]]; then
      a=$(printf %d "'$a") b=$(printf %d "'$b")
      len=$((a - b))
      total=$((total * (${len#-} + 1)))
    fi
    (( total > 1024 )) && total=0
  done
  if (( total )) && eval "exp=( $e )" 2>/dev/null; then
    for ch in ${exp[@]+"${exp[@]}"}; do
      words+=("$ch"); marks+=("$wsub")
    done
  else
    SHEPHERD_SPLIT_TRUNCATED=1
    words+=("$word"); marks+=("$wsub")
  fi
}

_shepherd_end_segment() {
  _shepherd_end_word
  if (( ${#words[@]} )); then
    (( segsub )) && marks=("${marks[@]/*/1}")
    _shepherd_emit "$depth" "${marks[*]}" "${words[@]}"
  fi
  words=() marks=() segsub=0
}

# In _shepherd_emit, before a re-split of w[FROM] to w[TO-1] (eval, env -S,
# sh -c): when one of them held a substitution, mark every word the re-split
# makes, since the substitution body is already gone from the text.
_shepherd_inherit() {
  local j off=$((${#m[@]} - ${#w[@]}))
  for (( j = $1; j < $2; j++ )); do
    [[ "${m[off + j]:-0}" == 1 ]] && sub_inherit=1
  done
  return 0
}

_shepherd_emit() {
  local depth="$1" k opt sub_inherit=${sub_inherit:-0}
  local -a m
  read -ra m <<<"$2"
  shift 2
  local -a w=("$@")
  while (( ${#w[@]} )); do
    if [[ "${w[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      w=("${w[@]:1}"); continue
    fi
    case "${w[0]##*/}" in
      if | then | else | elif | do | while | until | select | coproc | '{' | '!' | nohup | builtin)
        w=("${w[@]:1}") ;;
      function)
        w=("${w[@]:2}") ;;
      exec)
        w=("${w[@]:1}")
        while [[ "${w[0]:-}" == -* ]]; do
          case "${w[0]}" in
            -a) w=("${w[@]:2}") ;;
            *) w=("${w[@]:1}") ;;
          esac
        done ;;
      eval)
        _shepherd_inherit 1 ${#w[@]}
        _shepherd_split "${w[*]:1}" $((depth + 1)); return 0 ;;
      command | time | nice)
        w=("${w[@]:1}")
        while [[ "${w[0]:-}" == -* ]]; do
          case "${w[0]}" in
            -n) w=("${w[@]:2}") ;;
            *) w=("${w[@]:1}") ;;
          esac
        done ;;
      timeout)
        w=("${w[@]:1}")
        while [[ "${w[0]:-}" == -* ]]; do
          case "${w[0]}" in
            -s | -k) w=("${w[@]:2}") ;;
            *) w=("${w[@]:1}") ;;
          esac
        done
        w=("${w[@]:1}") ;;
      xargs)
        w=("${w[@]:1}")
        while [[ "${w[0]:-}" == -* ]]; do
          case "${w[0]}" in
            -I | -n | -L | -P | -d | -E | -s | -a) w=("${w[@]:2}") ;;
            *) w=("${w[@]:1}") ;;
          esac
        done ;;
      env)
        w=("${w[@]:1}")
        while [[ "${w[0]:-}" == -* ]]; do
          case "${w[0]}" in
            -S | --split-string)
              _shepherd_inherit 1 2
              _shepherd_split "${w[1]:-}" $((depth + 1)); return 0 ;;
            -u | -C | --unset | --chdir) w=("${w[@]:2}") ;;
            *) w=("${w[@]:1}") ;;
          esac
        done ;;
      sudo)
        w=("${w[@]:1}")
        while [[ "${w[0]:-}" == -* ]]; do
          case "${w[0]}" in
            -u | -g | -h | -p | -C | -D | -r | -t | -U | -T) w=("${w[@]:2}") ;;
            *) w=("${w[@]:1}") ;;
          esac
        done ;;
      *) break ;;
    esac
  done
  (( ${#w[@]} )) || return 0
  case "${w[0]##*/}" in
    bash | sh | zsh | dash | ksh)
      opt=0
      for (( k = 1; k < ${#w[@]}; k++ )); do
        case "${w[k]}" in
          -o | +o) k=$((k + 1)) ;;
          -*c*) [[ "${w[k]}" == --* ]] || opt=1 ;;
          -* | +*) ;;
          *) break ;;
        esac
      done
      if (( opt && k < ${#w[@]} )); then
        _shepherd_inherit $k $((k + 1))
        _shepherd_split "${w[k]}" $((depth + 1))
        return 0
      fi ;;
  esac
  w=("${w[@]//$'\n'/ }")
  m=("${m[@]:${#m[@]}-${#w[@]}}")
  local IFS="$SHEPHERD_SEP"
  SHEPHERD_SEGMENTS+=("${w[*]}")
  SHEPHERD_SEGMENT_SUBST+=("${m[*]}")
}

# shepherd_git_parse WORD...: when the words run git, sets SHEPHERD_GIT_SUB to
# the subcommand, SHEPHERD_GIT_ARGS to its arguments, SHEPHERD_GIT_CONFIG to
# the `-c` / `--config-env` settings before it, SHEPHERD_GIT_DIRS to its `-C`
# dirs, and SHEPHERD_GIT_REDIRECT to 1 when it sets --git-dir or --work-tree.
# Returns 1 for anything else.
shepherd_git_parse() {
  [[ "${1##*/}" == git ]] || return 1
  shift
  SHEPHERD_GIT_CONFIG=() SHEPHERD_GIT_DIRS=() SHEPHERD_GIT_REDIRECT=0
  while (( $# )); do
    case "$1" in
      -c | --config-env) SHEPHERD_GIT_CONFIG+=("${2:-}"); shift; (( $# )) && shift ;;
      --config-env=*) SHEPHERD_GIT_CONFIG+=("${1#*=}"); shift ;;
      -C) SHEPHERD_GIT_DIRS+=("${2:-}"); shift; (( $# )) && shift ;;
      --git-dir | --work-tree) SHEPHERD_GIT_REDIRECT=1; shift; (( $# )) && shift ;;
      --git-dir=* | --work-tree=*) SHEPHERD_GIT_REDIRECT=1; shift ;;
      --namespace) shift; (( $# )) && shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  SHEPHERD_GIT_SUB="${1:-}"
  (( $# )) && shift
  SHEPHERD_GIT_ARGS=("$@")
}

# shepherd_gh_parse WORD...: sets SHEPHERD_GH_POS to the words that are not
# options (the value of -R / --repo dropped), and SHEPHERD_GH_WRITE to 1 when
# they set a method other than GET (-X, --method), or set none and send a
# field or --input, which makes `gh api` send a POST.
shepherd_gh_parse() {
  local a prev="" method="" fields=0
  SHEPHERD_GH_POS=()
  for a in "$@"; do
    case "$prev" in
      -R | --repo) prev=""; continue ;;
      -X | --method) method=$a ;;
    esac
    case "$a" in
      -X?*) method=${a#-X} ;;
      --method=*) method=${a#--method=} ;;
      -f | -F | --field | --raw-field | --input | -f?* | -F?* | --field=* | --raw-field=* | --input=*) fields=1 ;;
      -*) ;;
      *) SHEPHERD_GH_POS+=("$a") ;;
    esac
    prev=$a
  done
  case "$method" in
    [Gg][Ee][Tt]) SHEPHERD_GH_WRITE=0 ;;
    "") SHEPHERD_GH_WRITE=$fields ;;
    *) SHEPHERD_GH_WRITE=1 ;;
  esac
}
