# Production coverage: every requirement, its control, and the test

Companion to the design document `docs/superpowers/specs/2026-10-29-mirror-production-design.md`
(local, not pushed) and to `docs/verify-production-guards.md`. For each requirement in the
threat model this says what covers it, whether it has actually been verified on the
production cluster, and the exact command that verifies it. Every write is a server-side
dry-run; nothing is changed except the three throw-away namespaces created in the setup.

Status values:

- **verified**: run on the production cluster, result recorded below.
- **reasoned**: concluded from configuration or Kubernetes semantics, not yet run.
- **lab only**: needs real objects and the operator; verified in the kind lab, not in production.
- **open**: the control does not exist today.

## Setup

No tenant is onboarded yet, so the tests use made-up tenants: two labelled namespaces,
groups bound to `admin`, `edit` and `view` the way the onboarding will do it, and one
unlabelled namespace with a project admin. The tenant Argo controller is tested in a
namespace it already manages (`kafka-cluster`).

```bash
SA=system:serviceaccount:<tenant-argo-ns>:developer-gitops-argocd-application-controller
INSTANCE=$(oc get clusterkeycloakinstance -o jsonpath='{.items[0].metadata.name}')
OPNS=$(oc get clusterkeycloakinstance "$INSTANCE" -o jsonpath='{.spec.auth.passwordGrant.secretRef.namespace}')
echo "SA=$SA INSTANCE=$INSTANCE OPNS=$OPNS"

oc create ns guard-test-a
oc create ns guard-test-b
oc create ns guard-test-c
oc label ns guard-test-a keycloak/tenant=team-a
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

Canaries. Each identity must be able to do something in its own namespace, otherwise a
later "forbidden" only means a typo:

```bash
oc $A auth can-i create pods -n guard-test-a      # yes
oc $E auth can-i create pods -n guard-test-a      # yes
oc $V auth can-i list pods -n guard-test-a        # yes
oc $C auth can-i create pods -n guard-test-c      # yes
oc --as=$SA auth can-i create pods -n kafka-cluster   # yes
```

## 1. Tenant editors and admins manage realm content in their namespaces

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

## 2. Viewers read realm content but cannot write it or read Secrets

Control: OLM `-view` roles aggregated into `view`; built-in `view` excludes secrets.
Status: **reasoned**.

```bash
oc $V auth can-i list keycloakusers -n guard-test-a     # yes
oc $V auth can-i create keycloakusers -n guard-test-a   # no
oc $V auth can-i get secrets -n guard-test-a            # no
```

## 3. A tenant cannot point an object at another realm, or at master

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

## 4. A namespace without the label cannot reference any realm

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

## 5. A tenant cannot use a namespaced realm reference (realmRef)

Control: realm guard, rule 1. Status: **reasoned** (not yet run in production).

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

## 6. Nobody creates a namespaced KeycloakRealm or KeycloakInstance outside the operator namespace

Control: platform-kinds guard, the only control; RBAC allows it for every `admin`/`edit`
through OLM. Status: KeycloakRealm **verified** 2026-10-29 as cluster admin;
KeycloakInstance **reasoned**; the RBAC side verified for the controller, reasoned for users.

```bash
oc $E auth can-i create keycloakrealms -n guard-test-a      # yes: finding, RBAC allows
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

Expected: `yes`, `yes`, then denied by `ValidatingAdmissionPolicy`, "KeycloakInstance is managed by the platform team".

## 7. The guards fail closed and cover every namespace except the operator's

Control: `failurePolicy: Fail` on both policies; bindings with `namespaceSelector` that
excludes only the operator namespace; `validationActions: [Deny]`. Status: **reasoned**
(the policies have been seen acting, their configuration has not been read).

```bash
oc get validatingadmissionpolicy -o custom-columns='NAME:.metadata.name,FAIL:.spec.failurePolicy'
oc get validatingadmissionpolicybinding -o yaml | grep -E "name:|validationActions|values:|operator:|key:" 
```

Expected: `Fail` on both; each binding `Deny`; the selector excludes exactly `$OPNS`.

## 8. A tenant cannot create, read, change or delete cluster-scoped realms and instances

Control: RBAC. The OLM roles do contain these kinds, but a RoleBinding never grants
cluster-scoped resources, and no user or group holds `admin`/`edit`/`view` through a
ClusterRoleBinding. Status: **verified** for the controller 2026-10-29; **reasoned** for users.

```bash
for v in get list create patch delete; do printf "%-8s" $v; oc $A auth can-i $v clusterkeycloakrealms; done      # all no
for v in get create; do printf "%-8s" $v; oc $A auth can-i $v clusterkeycloakinstances; done                    # all no
```

## 9. No group holds admin, edit or view cluster-wide

Control: routine; OLM put the Keycloak kinds into these roles, so a cluster-wide binding
is cluster-wide realm access. Status: **verified** 2026-10-29 (three platform service
accounts, no users or groups). Re-run whenever RBAC changes:

```bash
oc get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="admin" or .roleRef.name=="edit" or .roleRef.name=="view") | "\(.metadata.name): \(.roleRef.name) -> \([.subjects[]? | "\(.kind)/\(.name)"] | join(", "))"'
```

Expected: only `klusterlet-work-sa`, `template-instance-controller`, `template-instance-finalizer-controller`.

## 10. A tenant cannot reach the admin credentials or the operator

Control: RBAC; the admin Secret lives in `$OPNS`, where tenants have no bindings.
Status: **reasoned**.

```bash
oc $A auth can-i get secrets -n $OPNS                      # no
oc $A auth can-i create pods/exec -n $OPNS                 # no
oc $A auth can-i create serviceaccounts/token -n $OPNS     # no
oc $A auth can-i list secrets                              # no (cluster-wide)
```

## 11. A tenant cannot change the realm label on a namespace

Control: RBAC on namespaces; the project API refuses label changes for everyone.
Status: **verified** 2026-10-29 for a project admin (project API "field is immutable",
namespace API Forbidden) and for the controller (`can-i patch namespaces` no). Tenant
admin on its own labelled namespace:

```bash
oc $A label namespace guard-test-a keycloak/tenant=team-b --overwrite --dry-run=server   # Forbidden
oc $A label project guard-test-a keycloak/tenant=team-b --overwrite --dry-run=server     # field is immutable
oc $A label namespace guard-test-a keycloak/tenant- --dry-run=server                     # Forbidden
```

## 12. A tenant admin can share its own namespace, and nothing beyond it

Control: Kubernetes RBAC semantics. Sharing inside the namespace is **accepted** (it stays
inside the tenant's realm); escalation beyond the namespace or beyond `admin` is blocked by
the API server's escalation check. Status: **reasoned**.

```bash
oc $A create rolebinding share -n guard-test-a --clusterrole=edit --group=system:authenticated --dry-run=server   # created (server dry run): accepted
oc $A create rolebinding share -n guard-test-b --clusterrole=edit --group=system:authenticated --dry-run=server   # Forbidden
oc $A create rolebinding esc -n guard-test-a --clusterrole=cluster-admin --group=team-a-admin --dry-run=server   # Forbidden (escalation)
```

## 13. Indirect references cannot name another namespace

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

## 14. A tenant repository cannot write into another tenant's namespace through the shared controller

Control: the AppProject per team, with `destinations` limited to the team's own namespaces
and `clusterResourceWhitelist: []`. Destinations are configured (owner, 2026-10-29).
Status: **reasoned**; read the AppProject objects with the command below to record it.

Why this is in scope: the tenant controller holds `admin` in every managed namespace, also
other tenants'. A manifest in team A's repository with `metadata.namespace` set to one of
team B's namespaces and `clusterRealmRef: team-b` is applied by the controller in team B's
namespace, where the label says team-b, so the realm guard accepts it. Neither guard can
see this: the API server sees a trusted identity writing a correctly labelled namespace.
Only the AppProject's `destinations` stop it. (Verified 2026-10-29 that the controller has
no cluster-wide rights, so cluster-scoped objects are already out of reach; the whitelist
is belt and braces.)

Out of scope for Keycloak: Role, RoleBinding, argoproj.io kinds, ResourceQuota and
LimitRange from a tenant repository. With `admin` the tenant's own users can already create
Roles and RoleBindings interactively, and the escalation check keeps everything inside the
namespace and below `admin`; the damage stays in the tenant's own namespace and realm. A
`namespaceResourceBlacklist` is therefore optional; `argoproj.io` kinds are cheap to list
and remove the risk of tenants bootstrapping their own Applications if
apps-in-any-namespace is ever enabled.

This cannot be shown with a dry-run against the API server, because the AppProject is
enforced by Argo CD, not by Kubernetes. Verify the AppProject objects instead:

```bash
oc get appproject -n <tenant-argo-ns> -o custom-columns='NAME:.metadata.name,DESTINATIONS:.spec.destinations[*].namespace,CLUSTER:.spec.clusterResourceWhitelist'
```

Expected: every project lists only its own team's namespaces; the CLUSTER column is empty.

What the API server lets the controller do today, for the record (all `created (server dry run)`
or Forbidden as noted; none of it crosses a realm):

```bash
oc --as=$SA create rolebinding share -n kafka-cluster --clusterrole=admin --group=system:authenticated --dry-run=server   # created: inside the namespace
oc --as=$SA create quota q -n kafka-cluster --hard=pods=1 --dry-run=server                                               # Forbidden
```

## 15. The tenant controller has nothing cluster-wide

Control: the GitOps operator binds it per managed namespace only. Status: **verified**
2026-10-29 (no on every cluster-wide check).

```bash
for r in "patch namespaces" "create namespaces" "patch projects" "create clusterkeycloakrealms" "create clusterrolebindings" "list namespaces"; do printf "%-32s" "$r"; oc auth can-i $r --as=$SA; done
```

## 16. The cluster-scoped instance can read a Secret in any namespace

Control: only cluster admins and the infra Argo controller can create a
`ClusterKeycloakInstance`; the platform repository is therefore a path to every Secret in
the cluster. Status: **reasoned**; the schema was confirmed in the lab. Process control:
the infra instance syncs only the platform and onboarding repositories.

```bash
oc get crd clusterkeycloakinstances.keycloak.hostzero.com -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.auth.properties.passwordGrant.properties.secretRef.properties}' | jq keys
oc get applications -n openshift-gitops -o custom-columns='NAME:.metadata.name,REPO:.spec.source.repoURL'
```

Expected: `namespace` among the keys; every Application in the infra instance points at a platform-owned repository.

## 17. The operator version matches the lab

Status: **reasoned** ("0.13.1, I think").

```bash
oc get csv -A | grep -i hostzero
```

Expected: `0.13.1`. If not, pin the lab to the version shown.

## 18. Day-2 behaviour: delete, preserve, offboarding, moving an existing object

Control: operator behaviour and the realm guard's update path (metadata-only updates pass,
spec changes are re-checked). Status: **lab only**. Requires real objects and a real realm;
covered by the lab's day-2 tests, not reproducible with dry-runs.

## 19. Documentation findings (no test, a decision)

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

| # | Requirement | Status before this run | Result | Date |
|---|---|---|---|---|
| 1 | editors/admins create realm content | reasoned | | |
| 2 | viewers read only, no secrets | reasoned | | |
| 3 | other realm refused | verified (as admin) | | |
| 4 | unlabelled namespace refused | verified (as admin) | | |
| 5 | realmRef refused | reasoned | | |
| 6 | namespaced KeycloakInstance refused | reasoned (KeycloakRealm verified) | | |
| 7 | guards fail closed, cover all namespaces | reasoned | | |
| 8 | cluster kinds out of reach for users | reasoned (controller verified) | | |
| 9 | no cluster-wide admin/edit/view groups | verified | | |
| 10 | admin secret and operator out of reach | reasoned | | |
| 11 | tenant admin cannot change label | verified (project admin, controller) | | |
| 12 | sharing inside namespace only | reasoned | | |
| 13 | indirect refs cannot name a namespace | reasoned | | |
| 14 | tenant repo cannot write into another tenant's namespace | reasoned (destinations configured) | | |
| 15 | controller nothing cluster-wide | verified | | |
| 16 | instance secretRef reaches any namespace | reasoned | | |
| 17 | operator version | reasoned | | |
| 18 | day-2 | lab only | | |
