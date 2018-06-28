# How Testing Works


## Process
To test, we spin up a `kube-apiserver` (and `etcd3` to back it) and a `git` server. We then run `kubesync` to align the systems and check.

`kubesync` takes time to sync things up, so we need to allow this to be a running process. To shorten the phase, we have the `INTERVAL` set to 5.

## Tests
How we do it:

1. Starting phase: nothing configured
2. Repeat for each test:
    1. Seed three git repos, commit and push
    2. Wait 10 seconds
    3. Check that desired items exist and no others
3. Change some of the resources
4. Goto 2.

The tests we check are:

1. Do all of the resources define in the repos exist?
2. Do no other resources exist?

We have the following runs as of this writing:

1. Create basic resources: `Deployment`, `StatefulSet`, `DaemonSet`
2. Change properties on `Deployment` and `StatefulSet`, increase replica counts, add new `Deployment` and `StatefulSet`
3. Create Custom Resource Definition (CRD)
4. Add one instance of CRD

To do:

1. different version modes:
    * `branch:<branchname>`
    * `branch:master`
    * `commit:<short_hash>`
    * `commit:<long_hash>`
    * `tag:<tag>`
    * `tag:latest`
    * unset (default to `branch:master`)
2. Remove resources

### Repos
We have the following repos created:

* `system`
* `app1`
* `app2`

The repo `system` is meant to contain system-level ("privileged") services. When we support distinguishing privileged from non-privileged services, we will place privileged ones _only_ in `system`.

## Unit Tests
For now, the above are complete integration tests. This should be augmented with proper unit tests. This will happen in one of two ways (whichever comes first):

* The whole thing is rewritten in go using [kubernetes client-go](https://github.com/kubernetes/client-go), in which case we will write unit tests along with the go code
* The `sh` code is extracted into small standalone functions which are tested independently


