# Production coverage per requirement

Companion to `docs/superpowers/specs/2026-10-29-mirror-production-design.md` (local, not
pushed) and to `docs/verify-production-guards.md`. For each requirement R this says what
covers it, whether it has been verified on the production cluster, and the exact command
that verifies it. Every write is a server-side dry-run; nothing is changed except the three
throw-away namespaces created in the setup.

## Requirements

R1 to R6 are the README's. R8 is reworded for the production design (tenants hold `admin`,
so they can manage RBAC inside their namespace). R7, R9 and R10 are new; they came out of the
verification on 2026-10-29. Proposed for the README as well.

| ID | Requirement |
|---|---|
| R1 | Tenants manage everything inside their realm with Kubernetes objects in their own namespaces. |
| R2 | A tenant cannot see or change any other realm, the master realm, or realm settings owned by the platform. Enforced by the API server. |
| R3 | Keycloak admin credentials exist only where the operator runs. Tenants cannot read them or create their own connections. |
| R4 | Creating, renaming and deleting realms is a platform action. |
| R5 | Onboarding a tenant is a small, repeatable set of objects with no per-tenant code. |
| R6 | Deleting or editing an object does the expected thing, and there is a way to keep a Keycloak object when its Kubernetes object goes away. |
| R7 | The admission guards exist, fail closed, and cover every namespace except the operator's. |
| R8 | Tenants cannot pass rights beyond their own namespace, nor beyond what they hold themselves. |
| R9 | The tenant Argo CD controller holds nothing cluster-wide, and no group holds admin, edit or view cluster-wide. |
| R10 | The operator version and the roles it brings are known and documented. |

Status values:

- **verified**: run on the production cluster, result recorded below.
- **reasoned**: concluded from configuration or Kubernetes semantics, not yet run.
- **lab only**: needs real objects and the operator; verified in the kind lab, not in production.
- **open**: the control does not exist today.

## Setup

The tests create everything they need: two labelled namespaces, groups bound to `admin`,
`edit` and `view` the way the onboarding will do it, and one unlabelled namespace with a
project admin. The first labelled namespace also gets the `managed-by` label, so the GitOps
operator binds the tenant Argo controller there exactly as it does for a real tenant.

```bash
ARGONS=<tenant-argo-ns>          # the namespace the developer-gitops instance runs in
SA=system:serviceaccount:$ARGONS:developer-gitops-argocd-application-controller
INSTANCE=$(oc get clusterkeycloakinstance -o jsonpath='{.items[0].metadata.name}')
OPNS=$(oc get clusterkeycloakinstance "$INSTANCE" -o jsonpath='{.spec.auth.passwordGrant.secretRef.namespace}')
echo "SA=$SA INSTANCE=$INSTANCE OPNS=$OPNS"

oc create ns guard-test-a
oc create ns guard-test-b
oc create ns guard-test-c
oc label ns guard-test-a keycloak/tenant=team-a argocd.argoproj.io/managed-by=$ARGONS
oc label ns guard-test-b keycloak/tenant=team-b
for r in admin edit view; do
  oc create rolebinding tenant-$r -n guard-test-a --clusterrole=$r --group=team-a-$r
done
oc create rolebinding guard-test-admin -n guard-test-c --clusterrole=admin --group=guard-test-admins

A="--as=team-a-user --as-group=team-a-admin"
E="--as=team-a-user --as-group=team-a-edit"
V="--as=team-a-user --as-group=team-a-view"
C="--as=other-user --as-group=guard-test-admins"
```

The GitOps operator needs a moment to create the controller's binding in guard-test-a:

```bash
oc get rolebinding -n guard-test-a | grep argocd-application-controller
```

Canaries. Each identity must be able to do something in its own namespace, otherwise a
later "forbidden" only means a typo:

```bash
oc $A auth can-i create pods -n guard-test-a      # yes
oc $E auth can-i create pods -n guard-test-a      # yes
oc $V auth can-i list pods -n guard-test-a        # yes
oc $C auth can-i create pods -n guard-test-c      # yes
oc --as=$SA auth can-i create pods -n guard-test-a   # yes
```

## R1. Tenants manage everything inside their realm

### R1.1 Editors and admins create realm content in every tenant namespace

Control: OLM-generated ClusterRoles aggregated into `admin`/`edit` (the team's own
`keycloak-realm-*` roles are a redundant subset). Status: **reasoned** for users; the
controller path was verified (`can-i create keycloakusers` yes, 2026-10-29).

```bash
oc $E auth can-i create keycloakusers -n guard-test-a     # yes
oc $A auth can-i create keycloakclients -n guard-test-a   # yes
cat <<EOF | oc $E apply --dry-run=server -n guard-test-a -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: coverage-check
spec:
  clusterRealmRef:
    name: team-a
  username: coverage-check
EOF
```

Expected: `yes`, `yes`, and `keycloakuser.keycloak.hostzero.com/coverage-check created (server dry run)`.

### R1.2 Viewers read realm content but cannot write it or read Secrets

Control: OLM `-view` roles aggregated into `view`; built-in `view` excludes secrets.
Status: **reasoned**.

```bash
oc $V auth can-i list keycloakusers -n guard-test-a     # yes
oc $V auth can-i create keycloakusers -n guard-test-a   # no
oc $V auth can-i get secrets -n guard-test-a            # no
```

## R2. A tenant cannot reach any other realm

### R2.1 An object cannot point at another realm, or at master

Control: realm guard, rule 3. Status: **verified** 2026-10-29 as cluster admin
("must be team-a in this namespace"). Run once as a tenant editor so RBAC and admission
are seen together:

```bash
cat <<EOF | oc $E apply --dry-run=server -n guard-test-a -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: coverage-check
spec:
  clusterRealmRef:
    name: master
  username: coverage-check
EOF
```

Expected: denied by `ValidatingAdmissionPolicy`, "must be team-a in this namespace".

### R2.2 A namespace without the label cannot reference any realm

Control: realm guard, rule 2. Status: **verified** 2026-10-29 as cluster admin
("is not onboarded for a Keycloak realm"). As the project admin of an unlabelled namespace,
who has the Keycloak kinds through `admin`:

```bash
oc $C auth can-i create keycloakusers -n guard-test-c   # yes: RBAC allows, the guard is the control
cat <<EOF | oc $C apply --dry-run=server -n guard-test-c -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: coverage-check
spec:
  clusterRealmRef:
    name: team-a
  username: coverage-check
EOF
```

Expected: `yes`, then denied by `ValidatingAdmissionPolicy`, "is not onboarded".

### R2.3 A tenant cannot use a namespaced realm reference (realmRef)

Control: realm guard, rule 1. Status: **reasoned**.

```bash
cat <<EOF | oc $E apply --dry-run=server -n guard-test-a -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: coverage-check
spec:
  realmRef:
    name: anything
  username: coverage-check
EOF
```

Expected: denied by `ValidatingAdmissionPolicy`, "realmRef ... not allowed".

### R2.4 Indirect references cannot name another namespace

Control: strict field validation on the API server, then the operator resolving references
in the object's own namespace. Status: the API-server half is **reasoned** (testable here);
the operator half is **lab only**.

```bash
cat <<EOF | oc $E apply --dry-run=server -n guard-test-a -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakRole
metadata:
  name: coverage-check
spec:
  clientRef:
    name: someone-elses-client
    namespace: guard-test-b
  name: hijack
  definition: {}
EOF
```

Expected: rejected with `unknown field "spec.clientRef.namespace"`.

### R2.5 A tenant cannot change the realm label on a namespace

Control: RBAC on namespaces; the project API refuses label changes for everyone.
Status: **verified** 2026-10-29 for a project admin (project API "field is immutable",
namespace API Forbidden) and for the controller (`can-i patch namespaces` no). Tenant
admin on its own labelled namespace:

```bash
oc $A label namespace guard-test-a keycloak/tenant=team-b --overwrite --dry-run=server   # Forbidden
oc $A label project guard-test-a keycloak/tenant=team-b --overwrite --dry-run=server     # field is immutable
oc $A label namespace guard-test-a keycloak/tenant- --dry-run=server                     # Forbidden
```

### R2.6 A tenant repository cannot write into another tenant's namespace through the shared controller

Control: the AppProject per team, with `destinations` limited to the team's own namespaces
and `clusterResourceWhitelist: []`. Destinations are configured (owner, 2026-10-29).
Status: **reasoned**; read the AppProject objects with the command below to record it.

Why this is in scope: the tenant controller holds `admin` in every managed namespace, also
other tenants'. A manifest in team A's repository with `metadata.namespace` set to one of
team B's namespaces and `clusterRealmRef: team-b` is applied by the controller in team B's
namespace, where the label says team-b, so the realm guard accepts it. Neither guard can
see this: the API server sees a trusted identity writing a correctly labelled namespace.
Only the AppProject's `destinations` stop it.

Out of scope for Keycloak: Role, RoleBinding, argoproj.io kinds, ResourceQuota and
LimitRange from a tenant repository. With `admin` the tenant's own users can already create
Roles and RoleBindings interactively (R8), and the damage stays in the tenant's own
namespace and realm. A `namespaceResourceBlacklist` is therefore optional; `argoproj.io`
kinds are cheap to list and remove the risk of tenants bootstrapping their own Applications
if apps-in-any-namespace is ever enabled. KeycloakRealm and KeycloakInstance need not be
listed: the platform-kinds guard refuses them for every identity (R4.1, R3.1).

This cannot be shown with a dry-run against the API server, because the AppProject is
enforced by Argo CD, not by Kubernetes. Verify the AppProject objects instead:

```bash
oc get appproject -n $ARGONS -o custom-columns='NAME:.metadata.name,DESTINATIONS:.spec.destinations[*].namespace,CLUSTER:.spec.clusterResourceWhitelist'
```

Expected: every project lists only its own team's namespaces; the CLUSTER column is empty.

### R2.7 No group holds admin, edit or view cluster-wide

Control: routine; OLM put the Keycloak kinds into these roles, so a cluster-wide binding
is cluster-wide realm access (read with `view`, create with `edit`). Status: **verified**
2026-10-29 (three platform service accounts, no users or groups). Re-run whenever RBAC
changes:

```bash
oc get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="admin" or .roleRef.name=="edit" or .roleRef.name=="view") | "\(.metadata.name): \(.roleRef.name) -> \([.subjects[]? | "\(.kind)/\(.name)"] | join(", "))"'
```

Expected: only `klusterlet-work-sa`, `template-instance-controller`, `template-instance-finalizer-controller`.

## R3. Admin credentials only where the operator runs; no tenant connections

### R3.1 Nobody creates a namespaced KeycloakInstance outside the operator namespace

Control: platform-kinds guard, the only control; RBAC allows it for every `admin`/`edit`
through OLM. Status: **reasoned** (the same policy was verified for KeycloakRealm, R4.1).

```bash
oc $E auth can-i create keycloakinstances -n guard-test-a   # yes: finding, RBAC allows
cat <<EOF | oc $E apply --dry-run=server -n guard-test-a -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakInstance
metadata:
  name: coverage-check
spec:
  baseUrl: https://keycloak.example.com
  auth:
    passwordGrant:
      secretRef:
        name: some-secret
EOF
```

Expected: `yes`, then denied by `ValidatingAdmissionPolicy`, "KeycloakInstance is managed by the platform team".

### R3.2 A tenant cannot reach the admin Secret or the operator

Control: RBAC; the admin Secret lives in `$OPNS`, where tenants have no bindings.
Status: **reasoned**.

```bash
oc $A auth can-i get secrets -n $OPNS                      # no
oc $A auth can-i create pods/exec -n $OPNS                 # no
oc $A auth can-i create serviceaccounts/token -n $OPNS     # no
oc $A auth can-i list secrets                              # no (cluster-wide)
```

### R3.3 A tenant cannot create or read cluster-scoped instances

Control: RBAC. The OLM roles contain the kind, but a RoleBinding never grants
cluster-scoped resources, and no user or group holds `admin`/`edit`/`view` through a
ClusterRoleBinding (R2.7). Status: **verified** for the controller 2026-10-29; **reasoned**
for users.

```bash
for v in get create; do printf "%-8s" $v; oc $A auth can-i $v clusterkeycloakinstances; done   # all no
```

### R3.4 The cluster-scoped instance can read a Secret in any namespace

Control: only cluster admins and the infra Argo controller can create a
`ClusterKeycloakInstance`; the platform repository is therefore a path to every Secret in
the cluster. Status: **reasoned**; the schema was confirmed in the lab. Process control:
the infra instance syncs only the platform and onboarding repositories.

```bash
oc get crd clusterkeycloakinstances.keycloak.hostzero.com -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.auth.properties.passwordGrant.properties.secretRef.properties}' | jq keys
oc get applications -n openshift-gitops -o custom-columns='NAME:.metadata.name,REPO:.spec.source.repoURL'
```

Expected: `namespace` among the keys; every Application in the infra instance points at a platform-owned repository.

## R4. Realms are a platform action

### R4.1 Nobody creates a namespaced KeycloakRealm outside the operator namespace

Control: platform-kinds guard, the only control; RBAC allows it for every `admin`/`edit`
through OLM. Status: **verified** 2026-10-29 as cluster admin ("KeycloakRealm is managed by
the platform team and cannot be created in namespace guard-test-a"); the RBAC side verified
for the controller, reasoned for users.

```bash
oc $E auth can-i create keycloakrealms -n guard-test-a      # yes: finding, RBAC allows
cat <<EOF | oc $E apply --dry-run=server -n guard-test-a -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakRealm
metadata:
  name: coverage-check
spec:
  clusterInstanceRef:
    name: $INSTANCE
  realmName: coverage-check
  definition: {}
EOF
```

Expected: `yes`, then denied by `ValidatingAdmissionPolicy`, "managed by the platform team".

### R4.2 A tenant cannot create, read, change or delete cluster-scoped realms

Control: RBAC, as in R3.3. Status: **verified** for the controller 2026-10-29; **reasoned**
for users.

```bash
for v in get list create patch delete; do printf "%-8s" $v; oc $A auth can-i $v clusterkeycloakrealms; done   # all no
```

## R5. Onboarding without per-tenant code

Control: the onboarding ApplicationSet per tenant, driven by a flag and a list of
namespaces. No cluster test; covered by reading the generated objects for one tenant once
the first is onboarded:

```bash
oc get ns -l keycloak/tenant --show-labels
oc get clusterkeycloakrealm
```

Expected: every namespace of the tenant carries `keycloak/tenant=<realm>`, and one
`ClusterKeycloakRealm` with that name exists.

## R6. Day-2 behaviour

Control: operator behaviour and the realm guard's update path (metadata-only updates pass,
spec changes are re-checked). Status: **lab only**. Requires real objects and a real realm;
covered by the lab's day-2 tests, not reproducible with dry-runs.

## R7. The guards exist, fail closed, and cover every namespace except the operator's

Control: `failurePolicy: Fail` on both policies; bindings with a `namespaceSelector` that
excludes only the operator namespace; `validationActions: [Deny]`. Status: **reasoned**
(the policies have been seen acting, their configuration has not been read).

```bash
oc get validatingadmissionpolicy -o custom-columns='NAME:.metadata.name,FAIL:.spec.failurePolicy'
oc get validatingadmissionpolicybinding -o yaml | grep -E "name:|validationActions|values:|operator:|key:"
```

Expected: `Fail` on both; each binding `Deny`; the selector excludes exactly `$OPNS`.

This is the requirement to re-check on every change to the platform repository: the
platform-kinds guard is the only thing between any project admin and any realm (R4.1).

## R8. Tenants cannot pass rights beyond their own namespace

Control: Kubernetes RBAC semantics. Sharing inside the namespace is **accepted** (it stays
inside the tenant's realm, and holds for `oc` and for the tenant repository alike);
escalation beyond the namespace or beyond `admin` is blocked by the API server's
escalation check. Status: **reasoned**.

```bash
oc $A create rolebinding share -n guard-test-a --clusterrole=edit --group=system:authenticated --dry-run=server   # created (server dry run): accepted
oc $A create rolebinding share -n guard-test-b --clusterrole=edit --group=system:authenticated --dry-run=server   # Forbidden
oc $A create rolebinding esc -n guard-test-a --clusterrole=cluster-admin --group=team-a-admin --dry-run=server   # Forbidden (escalation)
```

## R9. The tenant controller holds nothing cluster-wide

Control: the GitOps operator binds it per managed namespace only. Status: **verified**
2026-10-29 (no on every cluster-wide check). The cluster-wide bindings of users and
groups are R2.7.

```bash
for r in "patch namespaces" "create namespaces" "patch projects" "create clusterkeycloakrealms" "create clusterrolebindings" "list namespaces"; do printf "%-32s" "$r"; oc auth can-i $r --as=$SA; done
```

Expected: `no` on every line.

## R10. The operator version and its roles are known and documented

### R10.1 The operator version matches the lab

Status: **reasoned** ("0.13.1, I think").

```bash
oc get csv -A | grep -i hostzero
```

Expected: `0.13.1`. If not, pin the lab to the version shown.

### R10.2 Documentation findings (no test, a decision)

- The team's `keycloak-realm-view/edit/admin` roles are shadowed by the OLM roles and
  control nothing. Verified 2026-10-29 (`oc get clusterrole -l rbac.authorization.k8s.io/aggregate-to-admin=true`).
- The RHBK operator's `Keycloak` and `KeycloakRealmImport` are aggregated into `admin` the
  same way: any project admin can deploy a Keycloak server in their namespace. Verified in
  the same listing. Decide whether that is intended.

## Clean up

```bash
oc delete ns guard-test-a guard-test-b guard-test-c
```

## Results

| Test | Status before this run | Result | Date |
|---|---|---|---|
| R1.1 editors/admins create realm content | reasoned | | |
| R1.2 viewers read only, no secrets | reasoned | | |
| R2.1 other realm and master refused | verified (as admin) | | |
| R2.2 unlabelled namespace refused | verified (as admin) | | |
| R2.3 realmRef refused | reasoned | | |
| R2.4 indirect refs cannot name a namespace | reasoned | | |
| R2.5 tenant cannot change the label | verified (project admin, controller) | | |
| R2.6 AppProject destinations per team | reasoned (configured) | | |
| R2.7 no cluster-wide admin/edit/view groups | verified | | |
| R3.1 namespaced KeycloakInstance refused | reasoned | | |
| R3.2 admin Secret and operator out of reach | reasoned | | |
| R3.3 cluster instances out of reach | reasoned (controller verified) | | |
| R3.4 instance secretRef reaches any namespace | reasoned | | |
| R4.1 namespaced KeycloakRealm refused | verified (as admin) | | |
| R4.2 cluster realms out of reach | reasoned (controller verified) | | |
| R5 onboarding objects | after first tenant | | |
| R6 day-2 | lab only | | |
| R7 guards fail closed, cover all namespaces | reasoned | | |
| R8 sharing inside namespace only | reasoned | | |
| R9 controller nothing cluster-wide | verified | | |
| R10.1 operator version | reasoned | | |
