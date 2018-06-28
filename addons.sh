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
gdir=/git/src
outdir=/git/out
sleepinterval=${INTERVAL:-300}
execcommand=${CMD}


# get the name of the repo, but be sure to remove .git off the end if it exists
reponame=$(basename $REPO)
reponame=${reponame%%.*git}

targetdir=$gdir/$reponame
tmpoutdir=$outdir/$reponame
log "cloning $REPO into $targetdir"
rm -rf $gdir
mkdir -p $gdir
git clone $REPO $targetdir
cd $targetdir

# what mode are we in?
if [ -z "$VERSION_MODE" ]; then
  VERSION_MODE="branch:master"
fi
versiontype=${VERSION_MODE%%:*}
versiondetail=${VERSION_MODE##*:}

if [ -z "$versiontype" ]; then
  log "must specify VERSION_MODE with one of commit,branch,tag or leave blank for branch:master"  >&2
  exit 1
fi

# loop forever
while true; do
  # make sure it is up to date
  log "updating from $REPO"
  # always update the origin
  git remote update origin --prune

  case "$versiontype" in
  branch)
    git checkout $versiondetail --quiet
    git pull origin $versiondetail --tags
    commit=$(git log --oneline --pretty=tformat:"%H" | head -1)
    log "updating from latest commit ${commit} on branch $versiondetail"
    ;;
  commit)
    git checkout master --quiet
    git pull origin master --tags
    git checkout $versiondetail --quiet
    log "updating from specific commit ${versiondetail}"
    ;;
  tag)
    git checkout master --quiet
    git pull origin master --tags
    commit=
    if [ "$versiondetail" = "latest" ]; then
      commitandtag=$(git for-each-ref --format='%(*committerdate:raw)%(committerdate:raw) %(refname) %(*objectname) %(objectname)' refs/tags | sort -n | awk '{ print $4, $3; }' | tail -1)
      tag=${commitandtag##* }
      tag=${tag##*/}
      commit=${commitandtag%% *}
      log "tag:latest set, updating from latest tag ${tag} commit ${commit}"
    else
      commit=$(git rev-list -n 1 ${versiondetail})
      log "tag:${versiondetail} set, updating from tag ${versiondetail} commit ${commit}"
    fi
    git checkout $commit --quiet
    ;;
  *)
    log "unknown VERSION_MODE $VERSION_MODE. Must be one of commit,branch,tag or leave blank for branch:master"  >&2
    exit 1
    ;;
  esac

  if [ -n "$execcommand" ]; then
    log "Running transformation $execcommand"
    INDIR=$targetdir OUTDIR=$tmpoutdir $execcommand
    log "kubernetes yml dir set to outdir $tmpoutdir"
    kdir=$tmpoutdir 
  else if [ -n "$YMLDIR" ]; then
    log "CMD empty, no transformation to run"
    log "kubernetes yml dir set to configured YMLDIR relative to repository root:  $YMLDIR"
    kdir=$targetdir/$YMLDIR
  else
    log "CMD empty, no transformation to run"
    log "kubernetes yml dir set to default relative to repository root: kubernetes/"
    kdir=$targetdir/kubernetes
  fi

  if [ -n "$DRYRUN" ]; then
    log "DRYRUN set, would have run: "
    log "kubectl -s http://localhost:8080 apply -f $kdir"
  else
    log "applying kubectl to directory $kdir"
    kubectl -s http://localhost:8080 apply -f $kdir
  fi
  log "done, awaiting next update in $sleepinterval seconds..."
  sleep $sleepinterval
done
