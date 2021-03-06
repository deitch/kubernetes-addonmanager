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
2. Optionally, run a preprocessor command in each repo to do any pre-processing and transformation
3. `kubectl apply -f <directory>`, where directory is one of:
    * the output of the optional pre-processor in step 2 above
    * the root directory of the repository (default behavious)
    * a different, explicitly configured directory in the repository

It is **expected** that this runs on a master, with `hostNetwork: true`, so it can run without waiting for any workers or the CNI network to be ready.

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
* `REPOCREDS`: if supplied, these credentials will be used to authenticate for repos in `REPO`. They should be in `<username>:<password>` format. If not supplied, and any of the repositories require credentials, it will fail. If your `<username>` does not require a password, then just set `REPOCREDS` to your username, e.g. `REPOCREDS=my_user_name`.
* `KUBECTL_OPTIONS`: A string of options to pass to `kubectl`, e.g. `KUBECTL_OPTIONS="--kubeconfig=/some/path --context=mykube"`
* `CURL_OPTIONS`: A string of options to pass to `curl`, if used when downloading config from `http://` or `https://` urls, e.g. `CURL_OPTIONS="--capath /var/lib/certs"`. This is the place to include SSL options, e.g. a custom cert, and http authentication options.
* `DRYRUN`: do not `kubectl apply` to the output, but run every other step
* `ONCE`: run the entire loop exactly once and exit. Used primarily for testing purposes.

### Repo
Repos with the actual resources to sync to your kubernetes cluster are configured in a configuration file. The configuration file should be [json](http://www.json.org) or [yml](http://yaml.org). `kubesync` will try to parse the config file first as `json`, and then as `yml`. If both fail, the processing fails and exits.

The format of the config file is an array of objects, each of which has the following properties:

* `url`: full URL (https only) to the git repo. **Required**
* `cmd`: optional transformation command to run once repository is cloned or, after each interval, updated. If not provided, no transformation command is run. If the command specified by `cmd` does not exist, no transformation will be run. It is the equivalent of `[ -e $cmd ] && $cmd `.
* `ymldir`: directory where the source yml files should be found, passed to `kubectl apply -f <YMLDIR>`. By default, root of the repository, but may be different, e.g. if `cmd` puts the output files in a different directory, for example `kubernetes/`.
*  `priviliged`: whether or not the kubernetes files in this repo have the right to run privileged containers or install into `kube-system`. Defaults to `false`. See details on implementation below.

`kubectl apply` reads the files from the following directory:

* If `cmd` is provided and exists, then `kubesync` **expects** the command to place its output files in the `kubesync`-provided directory in `$OUTDIR`, and will read files **only** from there. Else...
* If no `cmd` is provided, or the value of `cmd` as an executable is not found, then the value of `ymldir` relative to the repository root. Else...
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

## Privileged
As described above, resources deployed to kubernetes generally fall into two broad categories.

* Privileged resources are those that manage the system itself, with higher permission levels, e.g. running in the host's network namespace, running in the kubernetes `kube-system` namespace, or having higher capabilities and permissions.
* Regular resources are just applications, with none of the above.

kubesync supports distinguishing between "privileged" repos, or repos where you would store such system services, and "regular" repos. In a normal deployment, you will have just one or two privileged repos, but possibly many regular repos.

By default, kubesync treats each repo in its configuration as unprivileged, i.e. without higher-level permissions. To enable the deployment files in a repo to be privileged, simply mark it as so:

```json
  {
    "url": "https://github.com/foo/kube-system",
    "privileged": true
  }
```

kubesync enforces the privilege limitations at two levels:

1. Parsing
2. Deployment rights

#### Parsing
Before kubesync deploys configuration files from an unprivileged repo to kubernetes, it parses each file to check if it tries to do something privileged. If it does, parsing is stopped and deployment does not happen. kubesync looks for the following:

* `hostNetwork: true`
* `namespace: kube-system`

kubesync does _not_ check the following:

* privilege escalation: the logic for privilege escalation is complex, and already is built into kubernetes
* security context: the logic for enforcing security contexts is built into kubernetes, and we do not want to replicate it

We **strongly** recommend you not rely solely on kubesync's parsing, which only is intended as a safety valve. You should use [PodSecurityPolicy](https://kubernetes.io/docs/concepts/policy/pod-security-policy/) and proper vetting of your configuration files.

#### Deployment Rights
The kubesync deployment creates the following in installation:

* `kubesync` service account in the `kube-system` namespace
* `ClusterRoleBinding` from the `kubesync` service account to the `ClusterRole cluster-admin`, granting it the right to do nearly anything

In addition, when running, kubesync checks each namespace _except_ `kube-system` and creates a `RoleBinding` from the user `kubesync-limited` to the `ClusterRole admin` in each namespace.

When kubesync applies the configuration from a repository, it does the following:

* If the repository is configured as `privileged: true`, then apply it as the `kubesync` service account, i.e. bound to the `system:masters ClusterRole`
* If the repository is not configured as `privileged: true`, then apply it as the `kubesync-limited` user, i.e. restricted 

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

## Deployment
A sample deployment `yml` is available at [./kubesync-deploy.yml](./kubesync-deploy.yml). It can be deployed as is, or can be modified to suit your requirements.

To deploy it as is:

1. Ensure you have a secret named `kubesync` in the `kube-system` namespace with the configuration parameters you desire (see above).
2. Either download it and make it part of your cluster boot, or simply 

```
kubectl apply -f https://raw.githubusercontent.com/deitch/kubesync/master/kubesync-deploy.yml
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

