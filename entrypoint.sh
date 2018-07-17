#!/bin/sh
set -e

[ -n "$DEBUG" ] && set -x

log() {
  echo "$(date -R -u): $1"
}

repotodir() {
  local url=$1
  reponame=$(basename $url)
  reponame=${reponame%%.*git}
  echo $reponame
}

getrepo() {
  local url=$1
  local gdir=$2

  # get the name of the repo, but be sure to remove .git off the end if it exists
  reponame=$(repotodir $url)

  local targetdir=$gdir/$reponame
  local tmpoutdir=$outdir/$reponame
  log "INFO: cloning $url into $targetdir"
  git clone $url $targetdir
}

update_repo() {
  repo=$(basename $PWD)
  # make sure it is up to date
  log "INFO: updating from $repo"
  # always update the origin
  git remote update origin --prune
}

checkout_version() {
  local versiontype=$1
  local versiondetail=$2

  set +e

  # do we add debugging info?
  if [ -n "$DEBUG" ]; then
    log "DEBUG: PWD is $PWD"
    git branch --list
    git --no-pager log
  fi

  # in all cases, we are assuming we have commits and files. What if we don't? We should handle it sanely.
  case "$versiontype" in
  branch)
    git checkout $versiondetail --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout branch $versiondetail, might not exist yet or have any files"
      return 1
    fi
    git pull origin $versiondetail --tags
    commit=$(git log --oneline --pretty=tformat:"%H" | head -1)
    log "INFO: updating from latest commit ${commit} on branch $versiondetail"
    ;;
  commit)
    git checkout master --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout branch master, might not exist yet or have any files"
      return 1
    fi
    git pull origin master --tags
    git checkout $versiondetail --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout commit $versiondetail, might not exist yet or have any files"
      return 1
    fi
    log "INFO: updating from specific commit ${versiondetail}"
    ;;
  tag)
    git checkout master --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout branch master, might not exist yet or have any files"
      return 1
    fi
    git pull origin master --tags
    commit=
    if [ "$versiondetail" = "latest" ]; then
      commitandtag=$(git for-each-ref --format='%(*committerdate:raw)%(committerdate:raw) %(refname) %(*objectname) %(objectname)' refs/tags | sort -n | awk '{ print $4, $3; }' | tail -1)
      tag=${commitandtag##* }
      tag=${tag##*/}
      commit=${commitandtag%% *}
      log "INFO: tag:latest set, updating from latest tag ${tag} commit ${commit}"
    else
      commit=$(git rev-list -n 1 ${versiondetail})
      log "INFO: tag:${versiondetail} set, updating from tag ${versiondetail} commit ${commit}"
    fi
    git checkout $commit --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout commit $commit for tag $tag, might not exist yet or have any files"
      return 1
    fi
    ;;
  *)
    log "FATAL: unknown VERSION_MODE $VERSION_MODE. Must be one of commit,branch,tag or leave blank for branch:master"  >&2
    exit 1
    ;;
  esac

  set -e
}

preprocess() {
  local execcommand=$1
  local targetdir=$2
  local tmpoutdir=$3
  local ymldir=$4

  if [ -n "$execcommand" ]; then
    log "INFO: Running transformation $execcommand"
    actualcommand=$(echo "$execcommand" | INDIR=$targetdir OUTDIR=$tmpoutdir envsubst)
    INDIR=$targetdir OUTDIR=$tmpoutdir $actualcommand
    log "INFO: kubernetes yml dir set to outdir $tmpoutdir"
  elif [ -n "$ymldir" ]; then
    log "INFO: cmd empty, no transformation to run"
    log "INFO: kubernetes yml dir set to configured ymldir relative to repository root:  $ymldir"
    cp -r $targetdir/$ymldir/. $tmpoutdir
  else
    log "INFO: cmd empty, no transformation to run"
    log "INFO: kubernetes yml dir set to default of repository root"
    cp -r $targetdir/. $tmpoutdir
  fi
}

apply() {
  local ymldir=$1
  local dryrun=$2

  set +e 
  if [ -n "$dryrun" ]; then
    log "INFO: DRYRUN set, would have run: "
    log "INFO: kubectl $KUBECTL_OPTIONS apply -f $ymldir"
  else
    log "INFO: applying kubectl to directory $ymldir"
    kubectl $KUBECTL_OPTIONS apply -f $ymldir
    if [ $? -ne 0 ]; then
      log "ERROR: unable to apply kubectl due to error, skipping..."
      return 1
    fi
  fi

  set -e
}

# were credentials provided?
username=
password=
if [ -n "$REPOCREDS" ]; then
  username=${REPOCREDS%%:*}
  password=${REPOCREDS#*:}
  git config --global credential.helper 'store --file ~/.git-credentials'
fi

# we download repos to per-repo subdirs of /git/src
# processed output goes to per-repo subdirs /git/out
gdir=/git/src
outdir=/git/out
sleepinterval=${INTERVAL:-300}

# clean up everything at beginning
rm -rf $gdir $outdir
mkdir -p $gdir $outdir

#####
#
# determine mode for branch
#
#####

# what mode are we in?
if [ -z "$VERSION_MODE" ]; then
  VERSION_MODE="branch:master"
fi
versiontype=${VERSION_MODE%%:*}
versiondetail=${VERSION_MODE##*:}

if [ -z "$versiontype" ]; then
  log "FATAL: must specify VERSION_MODE with one of commit,branch,tag or leave blank for branch:master"  >&2
  exit 1
fi


#####
#
# Process config file
#
#####
config=${CONFIG:-/kubesync.json}

# does it exist?
if [ ! -e ${config} ]; then
  log "FATAL: Config file ${config} does not exist, exiting" >&2
  exit 1
fi

# convert to json for advanced processing
json=$(cat ${config} | yq r -j - )

# it must be an array or error out
set +e
echo $json | jq -e '. | type == "array"'
result=$?
set -e
if [ $result -ne 0 ]; then
  log "FATAL: Config file does not contain array, exiting" >&2
  exit 1
fi

# count how many repos we have?
count=$(echo $json | jq '. | length')

#####
#
# Initialize repos
#
#####

# loop through the repos
j=0
while [ $j -lt $count ]; do
  repo=$(echo $json | jq -r ".[$j].url")

  # we need a repo
  if [ -z "$repo" ]; then
    log "FATAL: Repository $j in config does not have a repo defined as property 'url'" >&2
    exit 1
  fi

  # were credentials provided? if so, save them
  if [ -n "$password" ]; then
    git config --global credential.${repo}.username ${username}
    echo "https://${username}:${password}@${repo##https://}" >> ~/.git-credentials
  fi

  # get the repo
  getrepo ${repo} ${gdir}

  j=$(( j + 1 ))
done


#####
# 
# keep up to date
#
#####

# loop forever
while true; do
  # go to each repo
  # loop through the repos
  j=0
  while [ $j -lt $count ]; do
    repo=$(echo $json | jq -r ".[$j].url")
    cmd=$(echo $json | jq -r ".[$j] | select(.cmd) | .cmd")
    ymldir=$(echo $json | jq -r ".[$j] | select(.ymldir) | .ymldir")
    reponame=$(repotodir $repo)

    cd $gdir 

    # clean up old output directory
    tmpoutdir=$outdir/$reponame
    rm -rf $tmpoutdir
    mkdir -p $tmpoutdir

    # do the rest from within the repo
    cd $gdir/$reponame

    update_repo
    checkout_version $versiontype $versiondetail || continue
    preprocess "$cmd" "$PWD" "$tmpoutdir" "$ymldir"
    apply "$tmpoutdir" "$DRYRUN" || continue

    j=$(( j + 1 ))
  done

  log "INFO: done, awaiting next update in $sleepinterval seconds..."
  sleep $sleepinterval
done

