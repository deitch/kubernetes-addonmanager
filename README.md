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

### Algorithm
For updating the cluster, there isn't anything fancy to do. It just does `kubectl apply -f ` to each directory containing resources.

For removing (future support), `kubesync`, on each run, retrieves all of the following from the server:

* pods
* deployments
* replicasets
* statefulsets
* secrets (optional)
* configmaps
* daemonsets
* ingresses
* services
* customresourcedefinitions
* all resources for each customresourcedefinition

It retrieves each one in [json](https://json.org), and then checks the `'.metadata.ownerReferences'` property:

* if it has one, this resource can be ignored, as it was created by some parent
* if it has none, this resource was created on its own, we will check it

It then checks if the resource (`Kind`,`Name`) tuple exists in the expected set, then it will be left alone, else it will be deleted.


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
The following are configuration options. They are in two groups:

* Global: Define how kubesync works.
* Repo: Define repos and how to use them.

### Global

* `CONFIG`: config file location. Defaults to `/kubesync.json`. Can be one of:
    * `/path`: absolute path relative to the container
    * `file://path`: absolute path relative to the container
    * `http://path`: http URL
    * `https://path`: https URL
* `GIT_SSL_CAPATH`: path to a directory containing CA certificates that git should trust, in the container. Defaults to empty (use default system certificates).
* `GIT_SSL_CAIFO`: path to a file containing CA certificates that git should trust, in the container. Defaults to empty (use default system certificates).
* `INTERVAL`: interval in seconds between first `git clone` and subsequent `git pull`, and each `git pull`, defaults to `300`
* `VERSION_MODE`: which mode to apply (see [addon-versions](#Addon_Versions) above). Select from the following:
    * `branch:<branchname>`: apply latest commit from the given branch
    * `branch:master`: apply latest commit from `master`. This is the default if no setting is provided.
    * `commit:<commit>`: apply the specific commit. Can be the full commit hash or the short version.
    * `tag:<tag>`: apply the specific tag.
    * `tag:latest`: apply the most recent tag that is on a commit in `master`
* `REPOCREDS`: if supplied, these credentials will be used to authenticate for repos in `REPO`. They should be in `<username>:<password>` format. If not supplied, and any of the repositories require credentials, it will fail.
* `KUBECTL_OPTIONS`: A string of options to pass to `kubectl`, e.g. `KUBECTL_OPTIONS="--kubeconfig=/some/path --context=mykube"`
* `CURL_OPTIONS`: A string of options to pass to `curl`, if used when downloading config from `http://` or `https://` urls, e.g. `CURL_OPTIONS="--capath /var/lib/certs"`. This is the place to include SSL options, e.g. a custom cert, and http authentication options.
* `DRYRUN`: do not `kubectl apply` to the output, but run every other step

Note that this can be run entirely _inside_ the pod, without any need for mapping local directories or storage. However, given that a `git clone` is expensive with large repositories, it is recommended to do this _only_ if the add-ons configuration repository is small.

### Repo
Repos are configured in a configuration file. The configuration file should be [json](http://www.json.org) or [yml](http://yaml.org). `kubesync` will try to parse the config file first as `json`, and then as `yml`. If both fail, the processing fails and exits.

The format of the config file is an array of objects, each of which has the following properties:

* `url`: full URL (https only) to the git repo. **Required**
* `cmd`: optional transformation command to run once repository is cloned or, after each interval, updated. If not provided, no transformation command is run. If the command specified by `cmd` does not exist, no transformation will be run. It is the equivalent of `[ -e $cmd ] && $cmd `.
* `ymldir`: directory where the source yml files should be found, passed to `kubectl apply -f <YMLDIR>`. By default, root of the repository, but may be different, e.g. if `cmd` puts the output files in a different directory, for example `kubernetes/`.
*  `priviliged`: whether or not the kubernetes files in this repo have the right to run privileged containers or install into `kube-system`. Defaults to `false`. **Not yet supported**. Until it is, _all_ repositories' `yml` foles can deploy privileged containers.

`kubectl apply` reads the files from the following directory:

* If `cmd` is provided and exists, then `kubesync` **expects** the command to place its output files in the `kubesync`-provided directory in `$OUTDIR`, and will read files **only** from there. Else...
* If no `cmd` is provided, or the value of `cmd` as an executable is not found, then the value of `ymldir` relative to the repository root. Else...
* The directory `kubernetes/` relative to the repository root if it exists. Else...
* The root of the reository.

`cmd` will be passed the following environment variables when run:

* `INDIR`: path to the repository as cloned locally. 
* `OUTDIR`: path to a temporary directory, outside of the repo path but unique to this repository. The directory is cleaned and recreated before each `cmd` run.

Thus, your command should read kubernetes files from wherever it feels relevant in its repo, which is rooted at `$INDIR`, and place its processed output at `$OUTDIR`. **`kubesync` will do `kubectl apply -f ` only to the `$OUTDIR` when a command is specified.**

Wherein `./transform.sh` should read its files from the value of `$INDIR` and place them in `$OUTDIR`.

In addition, we run `envsubst` on the cmdline, so any usage of `$INDIR` or `$OUTDIR` would be translated correctly. Thus, you could do the following in the command-line:

```json
{
  "cmd": "./transform.sh -indir $INDIR -outdir $OUTDIR",
}
```


## Sample Configuration

The following are example repository configs. They also are included in this repository as `kubesync.json` and `kubesync.yml`, respectively.

```json
[
  {
    "url": "https://github.com/foo/kube-system",
    "cmd": "./transform.sh",
    "privileged": true
  },
  {
    "url": "https://github.com/bar/app1",
    "ymldir": "kubernetes_dir/"
  },
  {
    "url": "https://github.com/zad/app2"
  }
]
```

```yml
- url: https://github.com/foo/kube-system
  cmd: ./transform.sh
  privileged: true
- url: https://github.com/bar/app1
  ymldir: kubernetes_dir/
- url: https://github.com/zad/app2
```


The following is sample kubernetes deployment `yml`:

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
        - name: CONFIG
          value: /kubesync/kubesync.json
        - name: INTERVAL
          value: "300"
        volumeMounts:
        - name: config
          mountPath: /kubesync
      volumes:
      - name: config
        configMap:
          name: kubesync-config
```

## Design
Currently kubesync is a shell script running in a container with `kubectl` installed. It is possible to control all resources this way, but it is far better to do so using the kubernetes client-go.

We plan eventually to migrate to go.

## Building

```
make build
``` 

## Testing

```
make test
```
# LICENSE
See [LICENSE](./LICENSE)

