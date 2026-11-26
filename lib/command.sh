#!/usr/bin/env bash
# Split a Bash tool command into simple commands for the PreToolUse hooks.
# Sourced, never executed. Works on bash 3.2.
#
# shepherd_split_command CMD fills SHEPHERD_SEGMENTS with one entry per simple
# command: its words, quotes removed, joined by $SHEPHERD_SEP. A segment ends at
# a newline, `;`, `&`, `|`, `(`, or `)`; the body of `$(...)` or backticks is a
# segment of its own. Leading `command`, `env`, `VAR=val`, `sudo`, and `time`
# are dropped, and the script of `bash -c` / `sh -c` is split in turn.
# It reads command shapes, not full shell syntax: heredoc bodies and arithmetic
# read as commands, which errs toward a deny.

SHEPHERD_SEP=$'\x1f'
SHEPHERD_SPLIT_DEPTH=4

shepherd_split_command() {
  SHEPHERD_SEGMENTS=()
  local LC_ALL=C
  _shepherd_split "$1" 0
}

_shepherd_split() {
  local s="$1" depth="$2" n=${#1} i=0 j level c q="" word="" inword=0
  local -a words=()
  (( depth > SHEPHERD_SPLIT_DEPTH )) && return 0
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
    if [[ "$c" == '$' && "${s:i+1:1}" == '(' ]]; then
      j=$((i + 2)); level=1
      while (( j < n && level > 0 )); do
        case ${s:j:1} in
          '(') level=$((level + 1)) ;;
          ')') level=$((level - 1)) ;;
        esac
        j=$((j + 1))
      done
      _shepherd_split "${s:i+2:j-i-2-(level == 0)}" $((depth + 1))
      i=$j; continue
    fi
    if [[ "$c" == '`' ]]; then
      j=$((i + 1))
      while (( j < n )) && [[ "${s:j:1}" != '`' ]]; do j=$((j + 1)); done
      _shepherd_split "${s:i+1:j-i-1}" $((depth + 1))
      i=$((j + 1)); continue
    fi
    if [[ "$q" == '"' ]]; then
      if [[ "$c" == '"' ]]; then q=""; else word+=$c; fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      "'" | '"')
        q=$c; inword=1 ;;
      ' ' | $'\t')
        _shepherd_end_word ;;
      $'\n' | ';' | '|' | '(' | ')')
        _shepherd_end_segment ;;
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
        word+=$c; inword=1 ;;
    esac
    i=$((i + 1))
  done
  _shepherd_end_segment
}

# Helpers of _shepherd_split: they read and reset its locals (bash dynamic scope).
_shepherd_end_word() {
  (( inword )) && words+=("$word")
  word=""; inword=0
}

_shepherd_end_segment() {
  _shepherd_end_word
  (( ${#words[@]} )) && _shepherd_emit "$depth" "${words[@]}"
  words=()
}

_shepherd_emit() {
  local depth="$1" k opt
  shift
  local -a w=("$@")
  while (( ${#w[@]} )); do
    if [[ "${w[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      w=("${w[@]:1}"); continue
    fi
    case "${w[0]##*/}" in
      command | time)
        w=("${w[@]:1}")
        while [[ "${w[0]:-}" == -* ]]; do w=("${w[@]:1}"); done ;;
      env)
        w=("${w[@]:1}")
        while [[ "${w[0]:-}" == -* ]]; do
          case "${w[0]}" in
            -S | --split-string)
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
    bash | sh)
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
        _shepherd_split "${w[k]}" $((depth + 1))
        return 0
      fi ;;
  esac
  w=("${w[@]//$'\n'/ }")
  local IFS="$SHEPHERD_SEP"
  SHEPHERD_SEGMENTS+=("${w[*]}")
}

# shepherd_git_parse WORD...: when the words run git, sets SHEPHERD_GIT_SUB to
# the subcommand, SHEPHERD_GIT_ARGS to its arguments, and SHEPHERD_GIT_CONFIG
# to the `-c` / `--config-env` settings before it. Returns 1 for anything else.
shepherd_git_parse() {
  [[ "${1##*/}" == git ]] || return 1
  shift
  SHEPHERD_GIT_CONFIG=()
  while (( $# )); do
    case "$1" in
      -c | --config-env) SHEPHERD_GIT_CONFIG+=("${2:-}"); shift; (( $# )) && shift ;;
      --config-env=*) SHEPHERD_GIT_CONFIG+=("${1#*=}"); shift ;;
      -C | --git-dir | --work-tree | --namespace) shift; (( $# )) && shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  SHEPHERD_GIT_SUB="${1:-}"
  (( $# )) && shift
  SHEPHERD_GIT_ARGS=("$@")
}
