#!/usr/bin/env bash
# verify_review.sh: Enforces human review verification trailer on agent commits before git push.

zero="0000000000000000000000000000000000000000"

while read -r local_ref local_sha remote_ref remote_sha; do
  if [ "$local_sha" = "$zero" ]; then
    continue
  fi

  if [ "$remote_sha" = "$zero" ]; then
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
      range="origin/main..$local_sha"
    else
      range="$local_sha"
    fi
  else
    range="$remote_sha..$local_sha"
  fi

  for commit in $(git rev-list "$range"); do
    msg=$(git log -1 --format=%B "$commit")
    # If commit mentions Task: or was created for contract/agent task, ensure human Approved-by trailer exists
    if echo "$msg" | grep -Eq "Task:|Agent:"; then
      if ! echo "$msg" | grep -Eq "Approved-by:[[:space:]]+.+"; then
        echo "❌ [GIT PUSH ABORTED]: Commit $commit requires human approval verification."
        echo "   Commit message missing: 'Approved-by: Human Name <email>'"
        echo "   Please review changes using :GitReview and approve with :Accept in Neovim."
        exit 1
      fi
    fi
  done
done

exit 0
