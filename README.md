# Keycloak tenant self-service

Give each application team its own Keycloak realm, which it manages with plain Kubernetes
objects in its own namespace, without ever holding Keycloak admin credentials or being able
to reach another team's realm.

This repository holds two Helm charts that implement this with the
[Hostzero keycloak-operator](https://keycloak-operator.hostzero.com/), and a lab that
proves it: a local kind cluster, Keycloak, and a test suite that tries to break the
isolation.

See [Running the lab and the tests](#running-the-lab-and-the-tests) to try it yourself.

## Requirements

| ID | Requirement |
|---|---|
| R1 | Tenants manage everything inside their realm (users, groups, roles, clients, identity providers, flows) with Kubernetes objects in their own namespace. |
| R2 | A tenant cannot see or change any other realm, the master realm, or realm settings owned by the platform. Enforced by the API server. |
| R3 | Keycloak admin credentials exist only where the operator runs. Tenants cannot read them or create their own connections. |
| R4 | Creating, renaming and deleting realms is a platform action. |
| R5 | Onboarding a tenant is a small, repeatable set of objects with no per-tenant code. |
| R6 | Deleting or editing an object does the expected thing, and there is a way to keep a Keycloak object when its Kubernetes object goes away. |
| R8 | Tenants cannot create, change or delete Roles or RoleBindings in their namespace, so they cannot pass their rights on. |

The test files in `tests/` are named after these IDs.

## How it works

| Path | Content |
|---|---|
| `charts/keycloak-platform` | The Keycloak connection (ClusterKeycloakInstance) and its admin Secret, plus three admission policies |
| `charts/keycloak-tenants` | Per tenant in `values.yaml`: a labelled Namespace, its ClusterKeycloakRealm, the `keycloak-realm-editor` Role and the RoleBindings for the tenant's editors |
| `tests/` | pytest tests against the API server and the Keycloak admin API, one file per requirement; helpers in `lab.py` |
| `kind/`, `keycloak/` | Cluster config and the lab Keycloak Deployment |

- **The platform owns the realms.** Each tenant's realm is a cluster-scoped
  `ClusterKeycloakRealm`. Tenants reference it from their namespace with
  `spec.clusterRealmRef` and fill it with content, but cannot create, change or delete it.
- **One namespace, one realm.** The label `keycloak.lab/tenant-realm` on the tenant
  namespace names the only realm objects in that namespace may use.
- **`hostzero-tenant-realm-guard`** (ValidatingAdmissionPolicy) rejects any object whose
  realm reference does not match the namespace label. RBAC cannot do this, because it
  cannot look at field values. The guard applies to every namespace except the operator's,
  so a namespace without the label cannot reference any realm at all.
- **`hostzero-platform-kinds-guard`** rejects namespaced `KeycloakRealm` and
  `KeycloakInstance` outside the operator namespace, for everyone.
- **`tenant-rbac-guard`** rejects changes to Roles and RoleBindings in tenant namespaces
  from anyone but platform identities, as a backstop in case a tenant is given `admin`.
- **Tenant editors** are an OIDC group per tenant, bound in their namespace to the
  `keycloak-realm-editor` Role and to the built-in `edit` role, never `admin`.

Onboard a tenant: add an entry under `tenants:` in `charts/keycloak-tenants/values.yaml`
and upgrade. The operator creates the realm in Keycloak. Removing the entry deletes the
realm, unless `preserveRealm: true` is set.

## Decisions

### A Role in each tenant namespace, not a shared ClusterRole

`keycloak-realm-editor` is rendered into every tenant namespace from one template in
`_helpers.tpl`.

- The usual drawback, rules duplicated and drifting between tenants, does not apply when
  every Role comes from the same template.
- A Role cannot be bound cluster-wide or aggregated into other roles. A shared
  ClusterRole bound by mistake with a ClusterRoleBinding was shown in the lab to break
  realm isolation. The editor of tenant-1 could create objects in namespace tenant-2 that
  target realm tenant-2, because the label there names tenant-2.
- `roleRef` on a RoleBinding cannot be changed, so switching between the two later would
  mean deleting and recreating every binding.

### The realm guard skips updates that do not change `spec`

Without this, offboarding locks up. If the platform removes a namespace's label while
objects still exist, the operator can no longer remove its finalizer, because that is an
update that the guard would reject, and the object is stuck forever. A `spec` that has not
changed was checked when it was written, so skipping it lets nothing new through.

### Namespaced realms and connections are blocked for everyone

A namespaced `KeycloakRealm` can reference the platform's `ClusterKeycloakInstance` and set
any `realmName`. In the lab, one in namespace tenant-1 with `realmName: tenant-2` took over
realm tenant-2 with the platform's admin login. The same works for `master`, and deleting
such an object deletes the realm it took over. Tenants do not have these kinds in their
Role, but other identities with broad rights in a tenant namespace, such as a GitOps
controller, could still create them. `hostzero-platform-kinds-guard` closes that.

### kind's admin group is a platform identity in `tenant-rbac-guard`

On kubeadm clusters such as kind, the admin user is in `kubeadm:cluster-admins`, not
`system:masters`. Without it in `rbacGuard.platformGroups`, the platform could not install
the tenant chart. On OpenShift it can be removed.

## GitOps

When Argo CD applies a manifest, the API server sees Argo CD's service account, not the
person who pushed to Git. If tenants deploy through Argo CD:

- Do not exempt an Argo CD instance that syncs tenant repositories from `tenant-rbac-guard`.
  The exemption would also cover RoleBindings in a tenant's repository. Exempt only the
  identity that runs onboarding, for example through sync impersonation per AppProject.
- Give each tenant an AppProject limited to its own repository and namespace, with no
  cluster-scoped resources and with `Role`, `RoleBinding`, `KeycloakRealm` and
  `KeycloakInstance` blacklisted.
- The admission policies hold for every identity, with one gap that only Argo CD can
  close: an object written into another tenant's namespace with that tenant's own realm.

## Running the lab and the tests

### 1. Install the tools

| Tool | What it is for | Install |
|---|---|---|
| Docker | Runs the kind cluster | https://docs.docker.com/engine/install/ |
| kind | Kubernetes cluster in Docker | https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| kubectl | Talks to the cluster | https://kubernetes.io/docs/tasks/tools/ |
| helm | Installs the operator and the charts | https://helm.sh/docs/intro/install/ |
| uv | Runs the Python tests and fetches their packages | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |

You do not need to install Python packages yourself: uv downloads pytest and requests
(listed in `tests/requirements.txt`) into a cache the first time the tests run. uv uses
the Python already on the machine, or downloads one if there is none.

Check that everything is in place:

```bash
docker info >/dev/null && kind version && kubectl version --client && helm version && uv --version
```

### 2. Start the lab

```bash
git clone https://github.com/afshinyavari/keycloak-tenant-self-service.git
cd keycloak-tenant-self-service
./up.sh
```

`up.sh` takes a few minutes the first time. It creates a kind cluster called
`keycloak-lab`, starts Keycloak in it, installs the Hostzero operator and both charts, and
waits until the realms tenant-1 and tenant-2 exist. It also switches kubectl to the lab
cluster (context `kind-keycloak-lab`). It is safe to run again.

### 3. Run the tests

```bash
uv run --with-requirements tests/requirements.txt pytest tests
```

The whole suite takes about a minute and a half. Every test is listed by name with
`PASSED` or `FAILED`, and a summary of any failures is printed at the end:

```
tests/test_r2_realm_isolation.py::test_cannot_point_at_master_realm PASSED   [ 34%]
...
======================== 73 passed in 85.29s ========================
```

The tests run against whatever cluster kubectl points at, so make sure it is the lab:
`kubectl config current-context` should print `kind-keycloak-lab`. They clean up after
themselves and can be run as often as you like.

To run only some of the tests:

```bash
# one file (one requirement)
uv run --with-requirements tests/requirements.txt pytest tests/test_r8_rbac.py

# every test with "master" in its name
uv run --with-requirements tests/requirements.txt pytest tests -k master

# one test, with the full error output if it fails
uv run --with-requirements tests/requirements.txt pytest tests/test_r6_day2.py::test_offboarding_a_namespace_with_objects_left --tb=long
```

### 4. Look around (optional)

Keycloak's admin console shows the realms and what the tests created in them:

```bash
kubectl -n keycloak port-forward svc/keycloak 8080
```

Then open http://localhost:8080 and log in as admin / admin.

### 5. Stop the lab

```bash
./down.sh
```

This deletes the kind cluster and everything in it.

### If something goes wrong

- **Many tests fail with "not found" or time out after a restart of your machine.** Keycloak
  keeps its data in memory, so the realms are gone when its pod restarts. Run `./up.sh`
  again.
- **`connection refused` from kubectl.** The cluster is not running, or kubectl points at
  another cluster. Run `./up.sh`, or `kubectl config use-context kind-keycloak-lab`.
- **A test fails with "denied, but for the wrong reason".** The request was rejected, but
  not by the check the test is about. The full error message is printed below it; usually
  the test's manifest is missing a field after an operator upgrade.

### How the tests are written

Each test is a Python function whose docstring explains what it checks and why. For
example, from `tests/test_r2_realm_isolation.py`:

```python
def test_cannot_point_at_master_realm():
    """tenant-1 points a user at the master realm, the one that controls all of Keycloak."""
    evil = keycloak_object("KeycloakUser", "evil", **in_realm("master"), username="evil")
    assert_denied(TENANT1.apply(evil, namespace="tenant-1"), because=WRONG_REALM)
```

- `TENANT1` is a developer in tenant-1. The tests act as them through kubectl
  impersonation, so the request goes through the same RBAC and admission checks as for a
  real user. `PLATFORM` is the cluster admin.
- `assert_denied` checks that the request was rejected, and *why*, so a test with a
  mistake in its manifest fails instead of passing by accident.
- The `keycloak` fixture reads Keycloak's admin API, to check where objects really landed.
- The helpers are in `tests/lab.py`; shared setup, such as the objects tenant-1 and
  tenant-2 own, is in `tests/conftest.py`.

## Lab setup

- **kind instead of a VM.** Validating admission policies are GA since Kubernetes 1.30,
  and kind runs 1.35. Nothing tested here needs a full cluster.
- **Keycloak 26.4 inside the cluster**, in dev mode on an in-memory database. All realms
  are lost when the pod restarts. Re-run `./up.sh` to recreate them.
- **Tenants are simulated with impersonation** (`kubectl --as=... --as-group=...`), not a
  real OIDC login. Impersonated requests go through the same RBAC and admission chain.
- **The tests check Keycloak itself** through the admin API, not only Kubernetes status,
  to see where an object actually landed.

## Verified behaviour worth knowing

- **Indirect refs stay in the tenant's own namespace.** `clientRef`, `userRef`,
  `parentGroupRef`, `identityProviderRef` and similar refs have only a `name` field. If a
  ref also sets `namespace:`, strict field validation rejects it. With
  `--validate=false`, the field is pruned and the ref resolves in the tenant's own
  namespace. This is why the kinds that the realm guard does not list (credentials, role
  mappings, protocol mappers, IdP mappers) are still pinned to the tenant's realm.
- **`spec.definition` is free-form**, because the operator preserves unknown fields. A
  `KeycloakComponent` with `definition.parentId` set to another realm's id becomes Ready.
  Keycloak still stores it in the tenant's own realm, because the URL path decides the
  realm, and it has no effect on the other realm. It is not a way across realms, but it
  can leave an orphaned component behind.
- **The operator does not correct drift.** It applies a realm's settings only when the
  Kubernetes object's spec changes. A change made directly in Keycloak stays in place, and
  the object still reports Ready.
- **The realm guards apply to cluster admins too.** Platform-owned objects that need a
  `realmRef` belong in the operator namespace, which is the only one excluded.
