#!/bin/sh
set -e

[ -n "$DEBUG" ] && set -x

# dependencies to run:
#  - docker (to launch, start and stop kubesync)
#  - docker-compose (to launch, start and stop backing services)

# everything else is in the container


# where does everything live?
RUNDIR=${RUNDIR:-${PWD}}
CRUNDIR=${CRUNDIR:-/test}

# what is the container image that has all of our tools?
if [ -z "$TOOLIMAGE" ]; then
    echo "FATAL: env var TOOLIMAGE must be set with the image that has our testing tools" >&2
    exit 1
fi
if [ -z "$IMAGE" ]; then
    echo "FATAL: env var IMAGE must be set with the image that runs kubesync" >&2
    exit 1
fi

# pause between actions and their load
PAUSE=10
# basic run command
alias drun="docker run --network=kubesync -d -v $RUNDIR:$CRUNDIR:ro -e KUBECTL_OPTIONS='--kubeconfig=$CRUNDIR/kubeconfig --context=kube' -e CURL_OPTIONS='--cacert $CRUNDIR/certificate.pem' -e INTERVAL=5 -e REPOCREDS=git:git -e GIT_SSL_CAINFO=$CRUNDIR/certificate.pem  -e DEBUG=${DEBUG} "
alias git="docker run -i -u ${UID:-$(id -u)} --rm --network=kubesync -v $RUNDIR:$CRUNDIR -v $RUNDIR/gitconfig:/etc/gitconfig:ro -v $RUNDIR/git-credentials:/etc/git-credentials:ro -e GIT_SSL_CAINFO=$CRUNDIR/certificate.pem $TOOLIMAGE git"
alias kubectl="docker run -i --rm --network=kubesync -v $RUNDIR:$CRUNDIR $TOOLIMAGE kubectl --kubeconfig=$CRUNDIR/kubeconfig --context=kube "
alias jq="docker run -i --rm $TOOLIMAGE jq"
alias yq="docker run -i --rm $TOOLIMAGE yq"


stop_services() {
  docker-compose -f $RUNDIR/docker-compose.yml kill
  docker-compose -f $RUNDIR/docker-compose.yml rm -f
}

start_services() {
  docker-compose -f $RUNDIR/docker-compose.yml up -d
}

init_repos() {
  # basic setup
  rm -rf $RUNDIR/tmp/
  mkdir -p $RUNDIR/tmp/

  for i in app1 app2 system; do
    git clone https://git/$i.git $CRUNDIR/tmp/$i
  done
}

#
commit_and_push() {
  local basedir=$1
  git -C $basedir/tmp/app1 add .; git -C $basedir/tmp/app1 diff-index --quiet HEAD || git -C $basedir/tmp/app1 commit -m "First commit"; git -C $basedir/tmp/app1 push origin master
  git -C $basedir/tmp/app2 add .; git -C $basedir/tmp/app2 diff-index --quiet HEAD || git -C $basedir/tmp/app2 commit -m "First commit"; git -C $basedir/tmp/app2 push origin master
  git -C $basedir/tmp/system add .; git -C $basedir/tmp/system diff-index --quiet HEAD || git -C $basedir/tmp/system commit -m "First commit"; git -C $basedir/tmp/system push origin master
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
  for i in secret pod replicaset deployment statefulset configmap ingress service; do
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
  cd $basedir/tmp
  # check each yml file
  for i in */*.yml; do
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
runtest() {
  local name="$1"
  local pause="$2"
  local rundir="$3"
  local crundir="$4"
  local cplist="$5"

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

  commit_and_push $crundir >&2

  # wait and test
  sleep $pause >&2
  tmptest=$(testit $name $rundir)
  echo "$tmptest"
}

RESULTS=
ALLCID=

CONFIGPATHS="$CRUNDIR/kubesync.json file://$CRUNDIR/kubesync.json http://git/config/kubesync.json https://git/config/kubesync.json"
VERSIONMODES="branch:master"

########
#
# Test different VERSION_MODE settings
#
#######

for mode in $VERSIONMODES; do
    stop_services
    start_services
    init_repos

    # run with master mode
    CID=$(drun -e CONFIG=$CRUNDIR/kubesync.json -e VERSION_MODE=$mode $IMAGE)
    ALLCID="$ALLCID $CID"

    tmptest=$(runtest one $PAUSE $RUNDIR $CRUNDIR "app1/one.yml:app1/kube.yml app2/one.yml:app2/kube.yml system/kubernetes/one.yml:system/kubernetes/kube.yml")
    # output them here in case anything crashes later
    echo "$tmptest"
    RESULTS="$RESULTS"$'\n'"$tmptest"

    if echo "$tmptest" | grep -q -i fail ; then
      docker logs $CID
    fi

    #
    # change deployment property and increase replica count, and add resources
    tmptest=$(runtest two $PAUSE $RUNDIR $CRUNDIR "app1/two.yml:app1/kube.yml app2/two.yml:app2/kube.yml")
    # output them here in case anything crashes later
    echo "$tmptest"
    RESULTS="$RESULTS"$'\n'"$tmptest"

    #
    # add CRD
    tmptest=$(runtest crd $PAUSE $RUNDIR $CRUNDIR "app1/crd.yml:app1/crd.yml")
    # output them here in case anything crashes later
    echo "$tmptest"
    RESULTS="$RESULTS"$'\n'"$tmptest"

    #
    # add item based on CRD
    tmptest=$(runtest crd_resource $PAUSE $RUNDIR $CRUNDIR "app2/crd_resource.yml:app2/crd_resource.yml")
    # output them here in case anything crashes later
    echo "$tmptest"
    RESULTS="$RESULTS"$'\n'"$tmptest"

    docker stop $CID

    stop_services
done

########
#
# Test different config location settings
#
#######
for path in $CONFIGPATHS; do
  # clean out and set up repos
  stop_services
  start_services
  init_repos

  CID=$(drun -e CONFIG=$path -e VERSION_MODE=branch:master $IMAGE)
  ALLCID="$ALLCID $CID"

  # do a basic install
  tmptest=$(runtest config:$path $PAUSE $RUNDIR $CRUNDIR "app1/one.yml:app1/kube.yml app2/one.yml:app2/kube.yml system/kubernetes/one.yml:system/kubernetes/kube.yml")
  # output them here in case anything crashes later
  echo "$tmptest"
  RESULTS="$RESULTS"$'\n'"$tmptest"

  docker stop $CID

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
exit 1
else
exit 0
fi
   	kubectl $KUBECTL_OPTIONS apply -f $ymldir

