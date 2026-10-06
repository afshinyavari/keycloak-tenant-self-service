# Keycloak tenant self-service

Give each application team its own Keycloak realm, which it manages with plain Kubernetes
objects in its own namespace, without ever holding Keycloak admin credentials or being able
to reach another team's realm.

This repository holds two Helm charts that implement this with the
[Hostzero keycloak-operator](https://keycloak-operator.hostzero.com/), and a lab that
proves it: a local kind cluster, Keycloak, and a test suite that tries to break the
isolation.

```bash
./up.sh                                                          # kind cluster, Keycloak, operator, both charts
uv run --with-requirements tests/requirements.txt pytest tests   # the tests
./down.sh
```

Requires Docker, kind, kubectl, helm and [uv](https://docs.astral.sh/uv/) (which fetches
Python packages for the tests). Keycloak admin console:
`kubectl -n keycloak port-forward svc/keycloak 8080`, then http://localhost:8080 (admin/admin).

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

## Tests

Each test is a Python function whose docstring explains what it checks and why. For
example, from `tests/test_r2_realm_isolation.py`:

```python
def test_cannot_point_at_master_realm():
    """tenant-1 points a user at the master realm, the one that controls all of Keycloak."""
    evil = keycloak_object("KeycloakUser", "evil", **in_realm("master"), username="evil")
    assert_denied(TENANT1.apply(evil, namespace="tenant-1"), because=WRONG_REALM)
```

`assert_denied` also checks *why* the request was rejected, so a test with a typo in its
manifest fails instead of passing by accident. Run one file or one test with
`... pytest tests/test_r8_rbac.py` or `... pytest tests -k master`.

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
