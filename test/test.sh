#!/bin/sh
set -e

[ -n "$DEBUG" ] && set -x

# dependencies to run:
#  - docker (to launch, start and stop kubesync)
#  - git (to make commits and push)
#  - tr/fold/head (to modify/generate text)
#  - kubectl (to talk to kube cluster)
#  - jq (to process json)
#  - yq (to process yml)

# we must be told where the source dir is so we can do a docker run and mount volumes
if [ -z "$SOURCEDIR" ]; then
  echo "Must have SOURCEDIR set" >&2
  exit 1
fi


# where does everything live?
RUNDIR=${RUNDIR:-/test}
KUBECONFIG=${KUBECONFIG:-${RUNDIR}/kubeconfig}

# pause between actions and their load
PAUSE=10
# basic run command
alias drun="docker run --network=kubesync -d -v $SOURCEDIR:/test:ro -e CONFIG=/test/kubesync.json -e KUBECTL_OPTIONS='--kubeconfig=/test/kubeconfig --context=kube' -e INTERVAL=5 -e REPOCREDS=git:git -e GIT_SSL_CAINFO=/test/certificate.pem  -e DEBUG=${DEBUG}"

commit_and_push() {
  local basedir=$1
  (
  cd $basedir/tmp/app1; git add *; git diff-index --quiet HEAD || git commit -m "First commit"; git push origin master
  cd $basedir/tmp/app2; git add *; git diff-index --quiet HEAD || git commit -m "First commit"; git push origin master
  cd $basedir/tmp/system; git add *; git diff-index --quiet HEAD || git commit -m "First commit"; git push origin master
  )
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
    kubectl --kubeconfig=$KUBECONFIG --context=kube get $i --all-namespaces -ojson | jq '.items |= map(select(.metadata.ownerReferences == null))' > $tmpdir/stage/$i.json
    cat $tmpdir/stage/$i.json | jq -r '.items[].metadata.name' > $tmpdir/stage/$i.txt
  done

  # we need a different loop for CRDs, because the names of them are different
  for i in customresourcedefinition; do
    kubectl --kubeconfig=$KUBECONFIG --context=kube get $i --all-namespaces -ojson | jq '.items |= map(select(.metadata.ownerReferences == null))' > $tmpdir/stage/$i.json
    cat $tmpdir/stage/$i.json | jq -r '.items[].spec.names.kind | ascii_downcase' > $tmpdir/stage/$i.txt
  done

  # get the customresourcedefinitions themselves
  # if any CRDs exist, get all of each type
  for i in $(cat $tmpdir/stage/customresourcedefinition.txt); do
    kubectl --kubeconfig=$KUBECONFIG --context=kube get $i --all-namespaces -ojson > $tmpdir/stage/$i.json
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
      local actual=
      if [ "$kind" = "customresourcedefinition" ]; then
        # if it is a customresourcedefinition, then:
        # - use spec.names.kind instead of .metadata.name to avoid the funky naming
        # - delete the namespace that is added as blank
        actual=$(cat $tmpdir/stage/$kind.json | jq -r -c --arg name $name '.items[] | select(.spec.names.kind | ascii_downcase == $name) ' )
      else
        # if there is no namespace given and is not crd, add it
        expected=$( echo $expected | jq -r -c ".metadata.namespace |= (if . == null then \"default\" else . end)" )
        actual=$(cat $tmpdir/stage/$kind.json | jq -r -c --arg name $name '.items[] | select(.metadata.name | ascii_downcase == $name)' )
      fi
      # tendency to add annotations that did not exist, so we ignore annotations
      actual=$(echo $actual | jq -r -c '.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration" | fromjson | del(.metadata.annotations)' )

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

# disable ssl cert checking for git because we are using a self-signed cert
git config --global http.sslVerify false
git config --global credential.helper 'store --file ~/.git-credentials'
git config --global credential.https://git.username git
git config --global user.name git
git config --global user.email "git@kubesync.com"

echo "https://git:git@git/app1.git" >> ~/.git-credentials
echo "https://git:git@git/app2.git" >> ~/.git-credentials
echo "https://git:git@git/system.git" >> ~/.git-credentials

# basic setup
rm -rf $RUNDIR/tmp/
mkdir -p $RUNDIR/tmp/

(cd $RUNDIR/tmp
git clone https://git/app1.git
git clone https://git/app2.git
git clone https://git/system.git
)

#
# testing system includes kubernetes directory
mkdir -p $RUNDIR/tmp/system/kubernetes

RESULTS=

######
# 
# master mode
#
######
# run with master mode
CID=$(drun -e VERSION_MODE=branch:master $IMAGE)

cp $RUNDIR/kubernetes/app1/one.yml $RUNDIR/tmp/app1/kube.yml
cp $RUNDIR/kubernetes/app2/one.yml $RUNDIR/tmp/app2/kube.yml
cp $RUNDIR/kubernetes/system/kubernetes/one.yml $RUNDIR/tmp/system/kubernetes/kube.yml

commit_and_push $RUNDIR

# wait and test
sleep $PAUSE
tmptest=$(testit one $RUNDIR)
# output them here in case anything crashes later
echo "$tmptest"
RESULTS="$RESULTS"$'\n'"$tmptest"

#
# change deployment property and increase replica count, and add resources
cp $RUNDIR/kubernetes/app1/two.yml $RUNDIR/tmp/app1/kube.yml
cp $RUNDIR/kubernetes/app2/two.yml $RUNDIR/tmp/app2/kube.yml

commit_and_push $RUNDIR

# wait and test
sleep $PAUSE
tmptest=$(testit two $RUNDIR)
# output them here in case anything crashes later
echo "$tmptest"
RESULTS="$RESULTS"$'\n'"$tmptest"

#
# add CRD
cp $RUNDIR/kubernetes/app1/crd.yml $RUNDIR/tmp/app1/

commit_and_push $RUNDIR

# wait and test
sleep $PAUSE
tmptest=$(testit crd $RUNDIR)
# output them here in case anything crashes later
echo "$tmptest"
RESULTS="$RESULTS"$'\n'"$tmptest"

#
# add item based on CRD
cp $RUNDIR/kubernetes/app2/crd_resource.yml $RUNDIR/tmp/app2/

commit_and_push $RUNDIR

# wait and test
sleep $PAUSE
tmptest=$(testit crd_resource $RUNDIR)
# output them here in case anything crashes later
echo "$tmptest"
RESULTS="$RESULTS"$'\n'"$tmptest"

### END
docker stop $CID

# we do not remove the container in case we need the logs
if [ -z "$DEBUG " ]; then
  docker rm $CID
fi

echo
echo "FINAL"
echo "$RESULTS"
echo

