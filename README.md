# Kubernetes AddOn Manager
Kubernetes add-in manager to control deployment of your `kube-system` services, including networking, logging, metrics, etc. Run just this to get started and point it at a repo that has all of your other services.

Every configurable amount of seconds, by default 300, `kubesync` will:

1. `git pull` a git repo with all of your system-level add-ons
2. Optionally, run a script in its root to do any pre-processing and transformation
3. `kubectl apply -f <directory>`, where directory is, by default, `kubernetes/` under the provided repo

It is **expected** that this runs on a master, with `hostNetwork: true`, so it can use kubernetes at the insecure port of `http://localhost:8080`.

## Addon Versions
When selecting what to apply from `git`, it can be configured to use any one of the following:

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
The following are configuration options:

* `REPO`: full URL (https only) to the git repo. **Required**
* `GITDIR`: directory where to clone the repository, defaults to `/git/repo`
* `CMD`: optional transformation command to run once repository is cloned or, after each interval, updated. If not provided, no transformation command is run.
* `INTERVAL`: interval in seconds between first `git clone` and subsequent `git pull`, and each `git pull`, defaults to `300`
* `YMLDIR`: directory where the yml files should be found, passed to `kubectl apply -f <YMLDIR>`. By default, `<GITDIR>/kubernetes/`, but may be different, e.g. if `CMD` puts the output files in a different directory.
* `VERSION_MODE`: which mode to apply (see [addon-versions](#Addon_Versions) above). Select from the following:
    * `branch:<branchname>`: apply latest commit from the given branch
    * `branch:master`: apply latest commit from `master`. This is the default if no setting is provided.
    * `commit:<commit>`: apply the specific commit. Can be the full commit hash or the short version.
    * `tag:<tag>`: apply the specific tag.
    * `tag:latest`: apply the most recent tag that is on a commit in `master`
* `REPOCREDS`: if necessary and supplied, these credentials will be used to authenticate for the `REPO`. They should be in `<username>:<password>` format. If not supplied, and the repository requires credentials, it will fail.
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
        - name: GITDIR
          value: /git/repo
        - name: CMD
          value: ./transform.sh -o /git/outdir -i /git/repo/kubernetes
        - name: INTERVAL
          value: "300"
        - name: YMLDIR
          value: /git/outdir
```

# LICENSE
See [LICENSE](./LICENSE)
