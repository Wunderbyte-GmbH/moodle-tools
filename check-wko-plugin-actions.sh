#!/usr/bin/env bash

set -uo pipefail

SCRIPT_NAME=${0##*/}

show_help() {
  cat <<EOF
Usage:
  $SCRIPT_NAME
  $SCRIPT_NAME --help
  $SCRIPT_NAME -h

Description:
  Checks the current HEAD commit of each configured plugin branch.

  A plugin passes only when:
    - GitHub Actions runs exist for the branch's current HEAD commit.
    - Every run is completed successfully.

  The script exits with:
    0  All plugins passed
    1  One or more plugins failed, are pending, or have no Actions runs
    2  Missing prerequisite, authentication problem, or invalid argument

Prerequisites:
  - Bash
  - GitHub CLI (gh)
  - jq
  - A GitHub account with access to the configured repositories

Install the required packages on Debian/Ubuntu:
  sudo apt update
  sudo apt install -y gh jq

Authenticate GitHub CLI:
  gh auth login --hostname github.com --git-protocol ssh

Verify authentication:
  gh auth status
  gh api user --jq .login

Notes:
  - The SSH option lets Git continue using your existing ~/.ssh key.
  - GitHub API and Actions access still use the token stored by gh.
  - Run this script as the same Linux user who performed gh auth login.
  - Do not use sudo to run this script.
  - DEFAULT means the repository's current default branch.
EOF
}

case "${1:-}" in
  -h|--help)
    show_help
    exit 0
    ;;
  "")
    ;;
  *)
    printf 'ERROR: unknown argument: %s\n\n' "$1" >&2
    show_help >&2
    exit 2
    ;;
esac

if (($# > 1)); then
  echo "ERROR: this script does not accept positional arguments." >&2
  echo "Run '$SCRIPT_NAME --help' for usage information." >&2
  exit 2
fi

# Format:
# repository|branch|Moodle plugin path
#
# Use DEFAULT to resolve the repository's default branch through GitHub.
PLUGINS=(
  "Wunderbyte-GmbH/local_sebcourse|master|local/sebcourse"
  "Wunderbyte-GmbH/moodle-availability_user|master|availability/condition/user"
  "Wunderbyte-GmbH/moodle-qtype_collabora|DEFAULT|question/type/collabora"
  "Wunderbyte-GmbH/moodle-local_wko_connect|master|local/wko_connect"
)

for command_name in gh jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$command_name" >&2
    printf 'Install prerequisites with: sudo apt install -y gh jq\n' >&2
    exit 2
  fi
done

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI is not authenticated." >&2
  echo "Run:" >&2
  echo "  gh auth login --hostname github.com --git-protocol ssh" >&2
  exit 2
fi

passed=0
failed=0

printf '%-8s %-54s %-16s %s\n' \
  "RESULT" "REPOSITORY" "BRANCH" "HEAD COMMIT"

printf '%-8s %-54s %-16s %s\n' \
  "--------" \
  "------------------------------------------------------" \
  "----------------" \
  "------------"

for entry in "${PLUGINS[@]}"; do
  IFS='|' read -r repository branch plugin_path <<<"$entry"

  if [[ "$branch" == "DEFAULT" ]]; then
    if ! branch=$(
      gh api "repos/$repository" \
        --jq '.default_branch' 2>/dev/null
    ); then
      printf '%-8s %-54s %-16s %s\n' \
        "FAIL" "$repository" "?" "cannot read repository"

      printf '         Plugin: %s\n\n' "$plugin_path"
      ((failed += 1))
      continue
    fi
  fi

  if ! commit_json=$(
    gh api "repos/$repository/commits/$branch" 2>/dev/null
  ); then
    printf '%-8s %-54s %-16s %s\n' \
      "FAIL" "$repository" "$branch" "branch/commit not found"

    printf '         Plugin: %s\n\n' "$plugin_path"
    ((failed += 1))
    continue
  fi

  sha=$(jq -r '.sha' <<<"$commit_json")
  short_sha=${sha:0:12}
  subject=$(
    jq -r '.commit.message | split("\n")[0]' <<<"$commit_json"
  )

  if ! runs_json=$(
    gh api --paginate \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "repos/$repository/actions/runs?branch=$branch&head_sha=$sha&per_page=100" \
      --jq '.workflow_runs' 2>/dev/null |
      jq -s 'add // []'
  ); then
    printf '%-8s %-54s %-16s %s\n' \
      "FAIL" \
      "$repository" \
      "$branch" \
      "$short_sha (cannot read Actions)"

    printf '         Plugin: %s\n\n' "$plugin_path"
    ((failed += 1))
    continue
  fi

  # Defensively retain only runs for this exact branch HEAD.
  exact_runs=$(
    jq \
      --arg branch "$branch" \
      --arg sha "$sha" \
      '[.[] |
        select(
          .head_branch == $branch and
          .head_sha == $sha
        )
      ]' <<<"$runs_json"
  )

  run_count=$(jq 'length' <<<"$exact_runs")

  if ((run_count == 0)); then
    printf '%-8s %-54s %-16s %s\n' \
      "FAIL" \
      "$repository" \
      "$branch" \
      "$short_sha (no Actions runs)"

    printf '         Plugin: %s\n' "$plugin_path"
    printf '         Commit: %s\n\n' "$subject"
    ((failed += 1))
    continue
  fi

  bad_runs=$(
    jq \
      '[.[] |
        select(
          .status != "completed" or
          .conclusion != "success"
        )
      ]' <<<"$exact_runs"
  )

  bad_count=$(jq 'length' <<<"$bad_runs")

  if ((bad_count == 0)); then
    printf '%-8s %-54s %-16s %s\n' \
      "PASS" \
      "$repository" \
      "$branch" \
      "$short_sha ($run_count green run(s))"

    ((passed += 1))
  else
    printf '%-8s %-54s %-16s %s\n' \
      "FAIL" \
      "$repository" \
      "$branch" \
      "$short_sha ($bad_count/$run_count not green)"

    while IFS=$'\t' read -r name status conclusion url; do
      printf '         - %s: status=%s, conclusion=%s\n' \
        "$name" "$status" "${conclusion:-null}"

      printf '           %s\n' "$url"
    done < <(
      jq -r \
        '.[] |
          [
            .name,
            .status,
            (.conclusion // ""),
            .html_url
          ] |
          @tsv' <<<"$bad_runs"
    )

    ((failed += 1))
  fi
done

printf '\nSummary: %d passed, %d failed\n' "$passed" "$failed"

if ((failed > 0)); then
  exit 1
fi
