# Kubernetes AddOn Manager
Kubernetes add-in manager to control deployment of your `kube-system` services, including networking, logging, metrics, etc. Run just this to get started and point it at a repo that
has all of your other services.

Every configurable amount of seconds, by default 300, will:

1. `git pull` a git repo with all of your system-level add-ons
2. Optionally, run a script in its root to do any pre-processing and transformation
3. `kubectl apply -f <directory>`, where directory is, by default, `kubernetes/` under the provided repo

It is **expected** that this runs on a master, with `hostNetwork: true`, so it can use kubernetes at the insecure port of `http://localhost:8080`.

The following are configuration options:

* `REPO`: full URL (https only) to the git repo. **Required**
* `GITDIR`: directory where to clone the repository, defaults to `/git/repo`
* `CMD`: optional transformation command to run once repository is cloned or, after each interval, updated. If not provided, no transformation command is run.
* `INTERVAL`: interval in seconds between first `git clone` and subsequent `git pull`, and each `git pull`, defaults to `300`
* `YMLDIR`: directory where the yml files should be found, passed to `kubectl apply -f <YMLDIR>`. By default, `<GITDIR>/kubernetes/`, but may be different, e.g. if `CMD` puts the output files in a different directory.
* `TAGONLY`: whether to apply the latest commit to `master` on the repo (unset `TAGONLY`), or only the most recent tag (`true`). Defaults to latest commit, i.e. unset. In general, this is used to control deployment to production vs other environments. In production, you might want to use `TAGONLY` so that only "blessed" changes go through.
* `REPOCREDS`: if necessary and supplied, these credentials will be used to authenticate for the `REPO`. They should be in `<username>:<password>` format. If not supplied, and the repository requires credentials, it will fail.

Note that this can be run entirely _inside_ the pod, without any need for mapping local directories or storage. However, given that a `git clone` is expensive with large repositories, it is recommended to do this _only_ if the add-ons configuration repository is small.

Sample yml to deploy is below. This sample has **no** volume mounts.

```yml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kube-addon-manager
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
      name: kube-addon-manager
  template:
    metadata:
      labels:
        name: kube-addon-manager
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
      - name: kube-addon-manager
        image: deitch/kubernetes-addonmanager:8f57a99980891ccc68701b94b94342f7ae0e02d6
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

