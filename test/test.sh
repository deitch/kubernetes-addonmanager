#!/bin/sh
set -e

[ -n "$DEBUG" ] && set -x

echo "Start test: $(date -R -u)"
TESTSTART=$(date +%s)

doexit() {
  local exitcode=$1
  TESTEND=$(date +%s)
  echo "End test: $(date -R -u)" >&2
  TESTTIME=$(( TESTEND - TESTSTART ))
  TESTMINS=$(( TESTTIME / 60 ))
  TESTSECS=$(( TESTTIME % 60 ))
  echo "Test time: ${TESTMINS}:${TESTSECS} "
  exit $exitcode
}

# dependencies to run:
#  - docker (to launch, start and stop kubesync)
#  - docker-compose (to launch, start and stop backing services)

# everything else is in the container


# where does everything live?
RUNDIR=${RUNDIR:-$(basename $0)}
CRUNDIR=${CRUNDIR:-/test}

# what is the container image that has all of our tools?
if [ -z "$TOOLIMAGE" ]; then
    echo "FATAL: env var TOOLIMAGE must be set with the image that has our testing tools" >&2
    doexit 1
fi
if [ -z "$IMAGE" ]; then
    echo "FATAL: env var IMAGE must be set with the image that runs kubesync" >&2
    doexit 1
fi

# pause between actions and their load
PAUSE=3
# basic run command
alias drun="docker run --network=kubesync -v $RUNDIR:$CRUNDIR:ro -e KUBECTL_OPTIONS='--kubeconfig=$CRUNDIR/kubeconfig --context=kube' -e CURL_OPTIONS='--cacert $CRUNDIR/certificate.pem' -e INTERVAL=10 -e REPOCREDS=git:git -e GIT_SSL_CAINFO=$CRUNDIR/certificate.pem  -e DEBUG=${DEBUG} "
alias drunonce="drun --rm -e ONCE=true"
alias drund="drun -d"
alias git="docker run -i -u ${UID:-$(id -u)} --rm --network=kubesync -v $RUNDIR:$CRUNDIR -v $RUNDIR/gitconfig:/etc/gitconfig:ro -v $RUNDIR/git-credentials:/etc/git-credentials:ro -e GIT_SSL_CAINFO=$CRUNDIR/certificate.pem $TOOLIMAGE git"
alias kubectl="docker run -i --rm --network=kubesync -v $RUNDIR:$CRUNDIR $TOOLIMAGE kubectl --kubeconfig=$CRUNDIR/kubeconfig --context=kube "
alias jq="docker run -i --rm $TOOLIMAGE jq"
alias yq="docker run -i --rm $TOOLIMAGE yq"

setconfig() {
  local confdir="$1"
  local target="$2"

  rm -f $confdir/kubesync.json
  ln -s $target $confdir/kubesync.json
  
}

stop_services() {
  docker-compose -f $RUNDIR/docker-compose.yml kill >&2
  docker-compose -f $RUNDIR/docker-compose.yml rm -f >&2
}

start_services() {
  local kubealive=1
  docker-compose -f $RUNDIR/docker-compose.yml up -d >&2
  # make sure API server is ready
  for i in $(seq 10); do
    set +e 
    kubectl get ns >/dev/null
    result=$?
    set -e 
    if [ $result -eq 0 ]; then
      kubealive=0
      break
    else 
      sleep 1
    fi
  done
  # did we get it?
  if [ $kubealive -ne 0 ]; then
    echo "FAIL: could not connect to kube in 5 seconds" >&2
    doexit 1
  fi
}

init_repos() {
  local repolist="$1"

  # make our server-side repos
  for dir in $repolist; do
    docker-compose -f $RUNDIR/docker-compose.yml exec git sh -c "rm -rf /git/$dir.git && mkdir -p /git/$dir.git && git -C /git/$dir.git init --bare" >&2
  done


  # clone locally
  rm -rf $RUNDIR/tmp/
  mkdir -p $RUNDIR/tmp/

  for i in $repolist; do
    git clone https://git/$i.git $CRUNDIR/tmp/$i
  done
}

#
commit_and_push() {
  local basedir=$1
  local repos="$2"
  local gitst=

  for r in $repos; do
    # only do work if something has changed
    gitst=$(git -C $basedir/tmp/$r status --porcelain 2>/dev/null)
    if [ -n "$gitst" ]; then
      git -C $basedir/tmp/$r add .; git -C $basedir/tmp/$r commit -m "First commit"; git -C $basedir/tmp/$r push origin master
    fi
  done
}

testit() {
  local section=$1
  local basedir=$2
  # how we test:
  # 1. get all of the resources from the kube cluster
  # 2. get all of the expected resources
  # 3. compare that everything in the expected resources exists in the cluster
  # 4. Future: check that nothing exists in the cluster that isn't in the expected resources except for specific exceptions
  local rnd=$(LC_CTYPE=C tr -dc A-Za-z0-9 < /dev/urandom | fold -w 32 | head -n 1)
  local tmpdir=/tmp/kubesynctest_${rnd}
  rm -rf $tmpdir
  mkdir -p $tmpdir/actual $tmpdir/stage
  # dump the actual
  # get all of the things we care about
  for i in secret pod replicaset deployment statefulset configmap ingress service daemonset; do
    kubectl get $i --all-namespaces -ojson | jq '.items |= map(select(.metadata.ownerReferences == null))' > $tmpdir/stage/$i.json
    cat $tmpdir/stage/$i.json | jq -r '.items[].metadata.name' > $tmpdir/stage/$i.txt
  done

  # we need a different loop for CRDs, because the names of them are different
  for i in customresourcedefinition; do
    kubectl get $i --all-namespaces -ojson | jq '.items |= map(select(.metadata.ownerReferences == null))' > $tmpdir/stage/$i.json
    cat $tmpdir/stage/$i.json | jq -r '.items[].spec.names.kind | ascii_downcase' > $tmpdir/stage/$i.txt
  done

  # get the customresourcedefinitions themselves
  # if any CRDs exist, get all of each type
  for i in $(cat $tmpdir/stage/customresourcedefinition.txt); do
    kubectl get $i --all-namespaces -ojson > $tmpdir/stage/$i.json
    cat $tmpdir/stage/$i.json | jq -r '.items[].metadata.name' > $tmpdir/stage/$i.txt
  done

  local fail=""

  # now check each item in each of our expected directories, and see if:
  # a- it exists
  # b- it is configured correctly
  # check each yml file
  for i in $(find $basedir/tmp -name '*.yml'); do
    # as json
    json=$(cat $i | yq r -j -d'*' -)
    count=$(echo $json | jq '. | length')


    j=0
    while [ $j -lt $count ]; do
      # get the kind and name
      local kind=$(echo $json | jq -r ".[$j].kind | ascii_downcase")
      local name=$(echo $json | jq -r ".[$j].metadata.name | ascii_downcase" )
      # customresourcedefinition kind is slightly different
      if [ "$kind" = "customresourcedefinition" ]; then
        name=$(echo $json | jq -r ".[$j].spec.names.kind | ascii_downcase")
      fi
      # tendency to add annotations that did not exist, so we ignore annotations
      local expected=$( echo $json | jq -r -c ".[$j] | del(.metadata.annotations) " )

      # check that the resource exists
      # end in "| cat" so that it doesn't return an error
      exists=$(cat $tmpdir/stage/$kind.txt | grep -i $name | cat)
      if [ -z "$exists" ]; then
        fail="$fail exists:$kind.$name"
      fi 

      # check that the resource matches
      # tendency to add annotations that did not exist, so we ignore annotations
      local actual=
      if [ "$kind" = "customresourcedefinition" ]; then
        # if it is a customresourcedefinition, then:
        # - use spec.names.kind instead of .metadata.name to avoid the funky naming
        # - delete the namespace that is added as blank
        actual=$(cat $tmpdir/stage/$kind.json | jq -r -c --arg name $name '.items[] | select(.spec.names.kind | ascii_downcase == $name) | .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration" | fromjson | del(.metadata.annotations)' )
      else
        # if there is no namespace given and is not crd, add it
        expected=$( echo $expected | jq -r -c ".metadata.namespace |= (if . == null then \"default\" else . end)" )
        actual=$(cat $tmpdir/stage/$kind.json | jq -r -c --arg name $name '.items[] | select(.metadata.name | ascii_downcase == $name) | .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration" | fromjson | del(.metadata.annotations)' )
      fi

      # delete blank namespaces
      actual=$(echo $actual | jq -r -c 'if .metadata.namespace == ""  then del(.metadata.namespace) else . end')
      expected=$(echo $expected | jq -r -c 'if .metadata.namespace == ""  then del(.metadata.namespace) else . end')

      if [ "$actual" != "$expected" ]; then
        fail="$fail mismatch:$kind.$name"
      fi
      j=$(( j + 1 ))
    done
  done  

  if [ -n "$fail" ]; then
    for i in $fail; do
      echo "FAIL $section $i"
    done
  else
    echo "PASS $section"
  fi
}
copy_and_commit() {
  local rundir="$1"
  local crundir="$2"
  local cplist="$3"

  local src=
  local target=
  local targetdir=
 
  for i in $cplist; do
    # split on : to find source and target
    src=${i%%:*}
    target=${i##*:}
    # make sure the dir exists
    targetdir=$(dirname $target)
    if [ ! -d $rundir/tmp/$targetdir ]; then
      mkdir -p $rundir/tmp/$targetdir
    fi
    cp $rundir/kubernetes/$src $rundir/tmp/$target
  done

  commit_and_push $crundir "app1 app2 app3 system" >&2
}


######
#
# TESTS
#
######

# to run all
#ALLTESTS="versionmodes configpaths dynamicconfig rolebinding privileged"
ALLTESTS="versionmodes configpaths dynamicconfig rolebinding"

# Test different VERSION_MODE settings
test_versionmodes() {
  local tmptest=
  local results=

  # set the original config
  setconfig $RUNDIR/config kubesync-original.json

  for mode in $VERSIONMODES; do
    stop_services
    start_services
    init_repos "app1 app2 app3 system"

    # run with master mode
    CID=$(drund -e CONFIG=$CRUNDIR/config/kubesync.json -e VERSION_MODE=$mode $IMAGE)
    ALLCID="$ALLCID $CID"

    copy_and_commit $RUNDIR $CRUNDIR "app1/one.yml:app1/kube.yml app2/one.yml:app2/kube.yml system/kubernetes/one.yml:system/kubernetes/kube.yml"
    # wait and test
    sleep $PAUSE >&2
    tmptest=$(testit versionmodes:one $RUNDIR)
    # output them here in case anything crashes later
    echo "$tmptest"
    results="$results"$'\n'"$tmptest"

    if echo "$tmptest" | grep -q -i fail ; then
      docker logs $CID >&2
    fi

    #
    # change deployment property and increase replica count, and add resources
    copy_and_commit $RUNDIR $CRUNDIR "app1/two.yml:app1/kube.yml app2/two.yml:app2/kube.yml"
    # wait and test
    sleep $PAUSE >&2
    tmptest=$(testit versionmodes:two $RUNDIR)
    # output them here in case anything crashes later
    echo "$tmptest"
    results="$results"$'\n'"$tmptest"

    #
    # add CRD
    copy_and_commit $RUNDIR $CRUNDIR "app1/crd.yml:app1/crd.yml"
    # wait and test
    sleep $PAUSE >&2
    tmptest=$(testit versionmodes:crd $RUNDIR)
    # output them here in case anything crashes later
    echo "$tmptest"
    results="$results"$'\n'"$tmptest"

    #
    # add item based on CRD
    copy_and_commit $RUNDIR $CRUNDIR "app2/crd_resource.yml:app2/crd_resource.yml"
    # wait and test
    sleep $PAUSE >&2
    tmptest=$(testit versionmodes:crd_resource $RUNDIR)
    # output them here in case anything crashes later
    echo "$tmptest"
    results="$results"$'\n'"$tmptest"

    docker stop $CID >&2

    stop_services
  done
  echo "$results"
}

# Test different config location settings
test_configpaths() {
 local tmptest=
 local results=
  for path in $CONFIGPATHS; do
  # clean out and set up repos
    stop_services
    start_services
    init_repos "app1 app2 app3 system"

    # do a basic install
    # no need to pause when used runonce
    copy_and_commit $RUNDIR $CRUNDIR "app1/one.yml:app1/kube.yml app2/one.yml:app2/kube.yml system/kubernetes/one.yml:system/kubernetes/kube.yml"

    # run it to update
    OUTPUT=$(drunonce -e CONFIG=$path -e VERSION_MODE=branch:master $IMAGE)

    tmptest=$(testit configpaths:$path $RUNDIR)
    # output them here in case anything crashes later
    results="$results"$'\n'"$tmptest"


  done
  echo "$results"
}

# Test changing config file dynamically
test_dynamicconfig() {
  local tmptest=
  local results=
  # set the original config
  setconfig $RUNDIR/config kubesync-original.json

  # clean out and set up repos
  stop_services
  start_services
  init_repos "app1 app2 app3 system"

  CID=$(drund -e CONFIG=$CRUNDIR/config/kubesync.json -e VERSION_MODE=branch:master $IMAGE)
  ALLCID="$ALLCID $CID"

  # do an install with the original config
  copy_and_commit $RUNDIR $CRUNDIR "app1/one.yml:app1/kube.yml app2/one.yml:app2/kube.yml system/kubernetes/one.yml:system/kubernetes/kube.yml"
  # wait and test
  sleep $PAUSE >&2
  tmptest=$(testit dynamicconfig:original $RUNDIR)

  results="$results"$'\n'"$tmptest"

  # set the modified config
  setconfig $RUNDIR/config kubesync-modified.json

  # do an install with the modified config
  copy_and_commit $RUNDIR $CRUNDIR "app3/one.yml:app3/kube.yml"
  # wait and test
  sleep $PAUSE >&2
  tmptest=$(testit dynamicconfig:modified $RUNDIR)
  results="$results"$'\n'"$tmptest"

  docker stop $CID >&2
  echo "$results"
}

# Test automatic RoleBinding creation
test_rolebinding() {
  local tmptest=
  # set the original config
  setconfig $RUNDIR/config kubesync-original.json

  # clean out and set up repos
  stop_services
  start_services
  init_repos "app1 app2 app3 system"

  # create a namespace - this should trigger creating the role
  testnamespace=roletest
  kubectl create namespace $testnamespace >&2

  OUTPUT=$(drunonce -e CONFIG=$CRUNDIR/config/kubesync.json -e VERSION_MODE=branch:master $IMAGE)

  # check that the role exists
  exists=$(kubectl get rolebinding -n $testnamespace kubesync -oname --no-headers 2>/dev/null)

  if [ -n "$exists" ]; then
    tmptest="PASS: namespace-role-creatione"
  else
    tmptest="FAIL: namespace-role-creation exists:role/$testnamespace/kubesync"
  fi

  # output them here in case anything crashes later
  echo "$tmptest"
}

# Test privileged and unprivileged
test_privileged() {
  # set the original config
  setconfig $RUNDIR/config kubesync-original.json

  # clean out and set up repos
  stop_services
  start_services
  init_repos "app1 app2 app3 system"

  # do an install with the original config
  copy_and_commit $RUNDIR $CRUNDIR "app1/one.yml:app1/kube.yml app2/one.yml:app2/kube.yml system/kubernetes/one.yml:system/kubernetes/kube.yml"

  # run it to update
  OUTPUT=$(drunonce -e CONFIG=$CRUNDIR/config/kubesync.json -e VERSION_MODE=branch:master $IMAGE)

  tmptest=$(testit privileged $RUNDIR)
  echo "$tmptest"
}


######
#
# MAIN
#
######

RESULTS=
ALLCID=

CONFIGPATHS="$CRUNDIR/config/kubesync.json file://$CRUNDIR/config/kubesync.json http://git/config/kubesync.json https://git/config/kubesync.json"
VERSIONMODES="branch:master"

# did we have a specific test listed?
if [ $# -gt 0 ]; then
  testlist=$@
else
  testlist="$ALLTESTS"
fi

if [ "$1" = "help" ]; then
  echo "Usage:"
  echo "$0 <test1> <test2> ... <testn>"
  echo
  echo "leave test list blank to run all"
  echo "Available tests: $ALLTESTS"
  doexit 1
fi

for t in $testlist; do
  tmptest=$(test_${t})
  # output them here in case anything crashes later
  echo "$tmptest"
  RESULTS="$RESULTS"$'\n'"$tmptest"
done

#####
#
# cleanup
#
#####

# we do not remove the container in case we need the logs
if [ -z "$DEBUG " ]; then
  docker rm $ALLCID
fi

echo
echo "FINAL"
echo "$RESULTS"
echo

# did we pass everything?
if echo "$RESULTS" | grep -q FAIL ; then
doexit 1
else
doexit 0
fi

