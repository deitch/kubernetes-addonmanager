# KubeSync
Kubernetes sync manager to control the state of all of your kubernetes services based on defined github repos.

This was originally called kubernetes "Pull Deploy", but since then has gained the name "GitOps".

It can handle two levels of kubernetes services:

* System services, i.e. privileged services that normally run in the `kube-system` namespace, but might also in certain other special system namespaces. These include include networking, logging, metrics, etc. 
* Applications, i.e. normal unprivileged applications that run as part of a regular workload.

To get your cluster into a well-known and good state, run just this, pointing it at one or more repos that have all of your other services.

## Why
Why work this way? Why not just have your Continuous Deployment pipeline, e.g. Jenkins or GitLab, use `kubectl` to push your deployments out to your kubernetes cluster?

There are 2 primary reasons:

1. Consistency
2. Reproducibility
3. Security

### Consistency
Can you confirm, right now, that the cluster is in the **precise** state you desire? Did every CD "push" job pass? Did anyone or any process make an unexpected change to the cluster?

Your cluster's reliability depends entirely upon its _actual_ state being consistent with the state its _desired_ state. However, things drift, processes fail, people and software make changes. 

Unless you are watching your cluster every second, you simply have _no idea_ if the actual and desired state are accurate.

### Reproducibility
Even if you completely trust your CD pipeline, and you can guarantee no one has touched your environment and no software has modified it, what happens if you need to rebuild your cluster? What if you are creating a new dev environment?

You need to go to your CD, find each job, and run it. Forget one, you have a problem.

### Security
Your CD environment is a less secure environment than your production (or likely staging or QA or ...). As such, should your CD environment have security credentials to _push_ into those secure environments? Or should your secure environment reach out and _pull_ precisely what it needs, even validating along the way?


## How It Works
Every configurable amount of seconds, by default 300, `kubesync` will:

1. `git pull` one or more git repos with all of your configurations
2. Optionally, run a script in each repo to do any pre-processing and transformation
3. `kubectl apply -f <directory>`, where directory is, by default, `kubernetes/` under each provided repo

It is **expected** that this runs on a master, with `hostNetwork: true`, so it can use kubernetes at the insecure port of `http://localhost:8080`.

## Versions
When selecting what to apply from `git` the given repo, it can be configured to use any one of the following:

* Branch: use the latest commit from the given branch
* Commit: use a specific commit
* Tag: use a specific tag
* Latest tag: use the most recent tag

The purposes of each is different.

* Commit and Tag: These provide the ability to stick with a very particular commit or tag until such time as you configure it differently.
* Branch: Use the branch `master` if you always want the latest mainline `master` version to be applied. This usually is done in pre-production environments, but also can be in production environments. Conversely, by applying a specific non-`master` branch, you can apply non-`master` branches and test out changes before merging into `master`.
* Latest tag: Use the most recent tag. This often is used in production environments, where applying a tag makes it deploy to production.

Set the version mode using the configuration variable `VERSION_MODE`.


## Configuration
The following are configuration options. All are set as environment variables. They are in two groups:

* Repo: Define repos and how to use them.
* Global: Define how kubesync works.

### Repo

* `REPO`: full URL (https only) to the git repo. **Required**
* `CMD`: optional transformation command to run once repository is cloned or, after each interval, updated. If not provided, no transformation command is run. If the file `CMD` does not exist, no transformation will be run. It is the equivalent of `[ -e $CMD ] && $CMD `.
* `YMLDIR`: directory where the source yml files should be found, passed to `kubectl apply -f <YMLDIR>`. By default, `<repodir>/kubernetes/`, but may be different, e.g. if `CMD` puts the output files in a different directory.

`kubectl apply` reads the files from the following directory:

* If `CMD` is provided and exists, then `kubesync` **expects** the command to place its output files in the `kubesync`-provided directory in `$OUTDIR`, and will read files **only** from there. Else...
* If no `CMD` is provided, or the value of `CMD` as an executable is not found, then the value of `YMLDIR` relative to the repository root. Else...
* The directory `kubernetes/` relative to the repository root if it exists. Else...
* The root of the reository.

Note that the `CMD` will be passed the following environment variables when run:

* `INDIR`: path to the repository as cloned locally. 
* `OUTDIR`: path to a temporary directory, outside of the repo path but unique to this repository. The directory is cleaned and recreated before each `CMD` run.

For example, if your command is `transform.sh`, and it wants to read the kubernetes files, which are in the repo in the subfolder `./kubernetes/`, and put them in a temporary working directory, following which `kubesync` will `kubectl apply <working_directory>`, it should set it as the following:

```sh
CMD=./transform.sh
```

Wherein `./transform.sh` will read its files from the value of `$INDIR` and place them in `$OUTDIR`.

### Global

* `INTERVAL`: interval in seconds between first `git clone` and subsequent `git pull`, and each `git pull`, defaults to `300`
* `VERSION_MODE`: which mode to apply (see [addon-versions](#Addon_Versions) above). Select from the following:
    * `branch:<branchname>`: apply latest commit from the given branch
    * `branch:master`: apply latest commit from `master`. This is the default if no setting is provided.
    * `commit:<commit>`: apply the specific commit. Can be the full commit hash or the short version.
    * `tag:<tag>`: apply the specific tag.
    * `tag:latest`: apply the most recent tag that is on a commit in `master`
* `REPOCREDS`: if supplied, these credentials will be used to authenticate for repos in `REPO`. They should be in `<username>:<password>` format. If not supplied, and any of the repositories require credentials, it will fail.
* `DRYRUN`: do not `kubectl apply` to the output, but run every other step

Note that this can be run entirely _inside_ the pod, without any need for mapping local directories or storage. However, given that a `git clone` is expensive with large repositories, it is recommended to do this _only_ if the add-ons configuration repository is small.

Sample yml to deploy is below. This sample has **no** volume mounts.

```yml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kubesync
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
spec:
  replicas: 1
  strategy:
    rollingUpdate:
      maxSurge: 10%
      maxUnavailable: 0
  selector:
    matchLabels:
      name: kubesync
  template:
    metadata:
      labels:
        name: kubesync
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      tolerations:
        - effect: NoSchedule
          operator: Exists
        - key: node.kubernetes.io/network-unavailable
          effect: NoSchedule
          operator: Exists
        - key: "CriticalAddonsOnly"
          operator: "Exists"
      # we specifically want to run on master
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                - key: kubernetes.io/role
                  operator: In
                  values: ["master"]
      containers:
      - name: kubesync
        image: deitch/kubesync:3979032795afbee10324b5c75b84e25e7984fb55
        env:
        - name: REPO
          value: https://github.com/namespace/repo.git
        - name: CMD
          value: ./transform.sh -o $OUTDIR -i $INDIR
        - name: INTERVAL
          value: "300"
```

# Design
Currently kubesync is just a shell script running in a container with `kubectl` installed. It is possible to control all resources this way, but it is far better to do so using the kubernetes client-go.

We plan eventually to migrate to go.

# LICENSE
See [LICENSE](./LICENSE)

