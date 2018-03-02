#!/bin/sh
set -e

function log {
  echo "$(date -R -u): $1"
}

if [ -z "$REPO" ]; then
  log "Must specify REPO environment variable for repo to clone" >&2
  exit 1
fi

# were credentials provided?
if [ -n "$REPOCREDS" ]; then
  username=${REPOCREDS%%:*}
  password=${REPOCREDS#*:}
  git config --global credential.helper 'store --file ~/.git-credentials'
  git config --global credential.${REPO}.username ${username}
  echo "https://${username}:${password}@${REPO##https://}" > ~/.git-credentials
fi

mkdir -p /git

# default download dir is /git/repo unless specified
gdir=${GITDIR:-/git/repo}
sleepinterval=${INTERVAL:-300}
execcommand=${CMD}
kdir=${YMLDIR:=$gdir/kubernetes/}

log "cloning $REPO into $gdir"
git clone $REPO $gdir
cd $gdir

# loop forever
while true; do
  # make sure it is up to date
  log "updating from $REPO"
  # ensure we are at the most recent
  git checkout master --quiet
  git pull origin master --tags
  # which version do we check out?
  if [ -n "$TAGONLY" ]; then
    commitandtag=$(git for-each-ref --format='%(*committerdate:raw)%(committerdate:raw) %(refname) %(*objectname) %(objectname)' refs/tags | sort -n | awk '{ print $4, $3; }' | tail -1)
    tag=${commitandtag##* }
    tag=${tag##*/}
    commit=${commitandtag%% *}
    log "TAGONLY set, updating from latest tag ${tag} commit ${commit}"
  else
    commit=$(git log --oneline --pretty=tformat:"%H" | head -1)
    log "updating from latest commit ${commit}"
  fi
  git checkout ${commit} --quiet

  if [ -n "$execcommand" ]; then
    log "Running transformation $execcommand"
    $execcommand
  else
    log "CMD empty, no transformation to run"
  fi
  log "applying kubectl to directory $kdir"
  kubectl -s http://localhost:8080 apply -f $kdir
  log "done, awaiting next update in $sleepinterval seconds..."
  sleep $sleepinterval
done
