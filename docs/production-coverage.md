# Requirements and the tests that verify them

For each requirement: what covers it, the commands that test it, and how to read the
output. Every write is a server-side dry-run: RBAC and admission run exactly as for a real
request, but nothing is stored. The only things created are the three test namespaces in
the setup, removed at the end.

## Requirements

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

## How the controls fit together

- **RBAC** decides whether an identity may touch a kind at all. Tenants get the Keycloak
  kinds through the built-in `admin`, `edit` and `view` roles, because the operator's OLM
  install aggregates every Hostzero kind into them. That includes the platform kinds
  (`KeycloakRealm`, `KeycloakInstance` and their cluster-scoped forms), so RBAC alone would
  let any namespace admin create them.
- **The realm guard** (ValidatingAdmissionPolicy) compares the realm an object points at
  with the `keycloak/tenant` label on the namespace. Wrong realm, or no label: refused.
- **The platform-kinds guard** refuses namespaced `KeycloakRealm` and `KeycloakInstance`
  everywhere except the operator namespace, for every identity including cluster admins.
- **Cluster-scoped kinds** are out of reach because tenants are bound per namespace, and a
  namespaced binding never grants a cluster-scoped resource.
- **The AppProject** per team limits where the shared Argo controller may write.

A refusal from a guard looks like `ValidatingAdmissionPolicy '<name>' ... denied request:
<message>`. A refusal from RBAC looks like `Forbidden: User "<user>" cannot <verb> resource
<resource>`. The difference matters: a test that expects the guard but gets RBAC has not
exercised the guard.

## Running everything at once

`scripts/verify.sh` runs the setup, the canaries, every test below and the cleanup, and
prints the results table with the date filled in. It asks for the Argo CD namespace and
takes the rest from the cluster. An unexpected answer is a FAIL row and the run continues;
if the tests cannot run at all (not logged in, no instance, a namespace cannot be created,
a canary fails) it cleans up and stops. Tests a person has to read are marked REVIEW.

```bash
scripts/verify.sh
```

The sections below are the same tests one by one, with what each answer means.

## Setup

The tests create everything they need: two labelled namespaces, groups bound to `admin`,
`edit` and `view` the way the onboarding does it, and one unlabelled namespace with a
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

`echo` must print all three values. An empty `INSTANCE` or `OPNS` makes later tests fail
on schema validation instead of on the control under test.

The GitOps operator needs a moment to create the controller's binding in guard-test-a:

```bash
oc get rolebinding -n guard-test-a | grep argocd-application-controller
```

### Canaries

Each identity must be able to do something in its own namespace. Run these first.

```bash
oc $A auth can-i create pods -n guard-test-a          # yes
oc $E auth can-i create pods -n guard-test-a          # yes
oc $V auth can-i list pods -n guard-test-a            # yes
oc $C auth can-i create pods -n guard-test-c          # yes
oc --as=$SA auth can-i create pods -n guard-test-a    # yes
```

- `yes`: the identity resolves to the binding the setup created; later refusals mean what they say.
- `no`: the identity is mistyped, or the binding is missing. Every later "forbidden" for
  that identity is meaningless until this says `yes`. For `$SA`, `no` also means the GitOps
  operator has not created its binding yet.

## R1. Tenants manage everything inside their realm

### R1.1 Editors and admins can create realm content

```bash
oc $E auth can-i create keycloakusers -n guard-test-a
oc $A auth can-i create keycloakclients -n guard-test-a
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

- `yes`, `yes`: `edit` and `admin` carry the Keycloak kinds.
- `created (server dry run)`: RBAC and both guards accept an object that points at the
  namespace's own realm. This is the everyday path, and the baseline for every refusal below.
- `no`, or `Forbidden`: the aggregated roles are missing; tenants cannot work at all.
- A `ValidatingAdmissionPolicy` refusal here: the realm guard is misconfigured, since the
  label and the reference match.

### R1.2 Viewers can read realm content but not write it, and cannot read Secrets

```bash
oc $V auth can-i list keycloakusers -n guard-test-a
oc $V auth can-i create keycloakusers -n guard-test-a
oc $V auth can-i get secrets -n guard-test-a
```

- `yes`, `no`, `no`: viewers see the realm content and nothing more.
- `yes` on the second: `view` carries write verbs; something aggregated more than it should.
- `yes` on the third: `view` can read passwords and client secrets; the role has been widened.

## R2. A tenant cannot reach any other realm

### R2.1 An object cannot point at another realm, or at master

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

- `ValidatingAdmissionPolicy` refusal, "must be team-a in this namespace": the realm guard
  pins objects to the namespace's realm. Replace `master` with `team-b` for the
  tenant-to-tenant case; same expected answer.
- `created (server dry run)`: a tenant can write into master or any other realm. The realm
  guard is missing or not bound to this namespace.
- `Forbidden`: RBAC refused before the guard ran; the canary for `$E` has not passed.

### R2.2 A namespace without the label cannot reference any realm

```bash
oc $C auth can-i create keycloakusers -n guard-test-c
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

- `yes`, then a `ValidatingAdmissionPolicy` refusal, "is not onboarded": RBAC lets any
  project admin create Keycloak objects, and the guard is what keeps a namespace without
  the label out of every realm. The `yes` is expected; it shows the guard is the control.
- `created (server dry run)`: any project in the cluster can write into any realm. The
  realm guard is missing, or its binding excludes this namespace.

### R2.3 A tenant cannot use a namespaced realm reference

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

- `ValidatingAdmissionPolicy` refusal mentioning `realmRef`: objects may only use the
  cluster-scoped realms the platform created.
- `created (server dry run)`: `realmRef` is allowed. On its own it is harmless, since a
  namespaced `KeycloakRealm` cannot be created (R4.1), but the guard's rule 1 is missing.

### R2.4 Indirect references cannot name another namespace

Kinds such as `KeycloakRole` and `KeycloakUserCredential` are placed in a realm through
another object (`clientRef`, `userRef`, `parentGroupRef`). The guard does not check them;
they are safe because a reference has no `namespace` field and the operator resolves it in
the object's own namespace.

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

- `unknown field "spec.clientRef.namespace"`: the API server rejects the field; references
  cannot point across namespaces.
- `created (server dry run)`: the schema accepts a namespace on references. Then the
  operator's behaviour decides, and that needs a test with real objects.

### R2.5 A tenant cannot change the realm label on a namespace

The label is what the realm guard trusts. Three ways to change it, as the tenant's admin.

```bash
oc $A label namespace guard-test-a keycloak/tenant=team-b --overwrite --dry-run=server
oc $A label project guard-test-a keycloak/tenant=team-b --overwrite --dry-run=server
oc $A label namespace guard-test-a keycloak/tenant- --dry-run=server
```

- `Forbidden`, `field is immutable, try updating the namespace`, `Forbidden`: no path. The
  namespace API needs patch on namespaces, which `admin` does not include; the project API
  does not allow label changes for anyone.
- `labeled (server dry run)` on any line: a tenant admin can move their namespace to
  another realm, or any project admin can move theirs. This breaks the whole model; a guard
  on namespace labels is needed. Also run the project line as `$C` to cover a project admin
  of a namespace that is not onboarded.

### R2.6 A tenant repository cannot write into another tenant's namespace

The tenant Argo controller holds `admin` in every namespace it manages, other tenants'
included. A manifest in team A's repository with `metadata.namespace` set to one of team
B's namespaces lands in a namespace whose label says team-b, and the realm guard accepts
it. Only the AppProject's `destinations` stop this, and Argo CD enforces that, not the API
server, so it cannot be dry-run. Read the AppProjects instead:

```bash
oc get appproject -n $ARGONS -o custom-columns='NAME:.metadata.name,DESTINATIONS:.spec.destinations[*].namespace,CLUSTER:.spec.clusterResourceWhitelist'
```

- Every project lists only its own team's namespaces, and CLUSTER is empty: a repository
  can only write where its team lives, and nothing cluster-scoped.
- A `*` or another team's namespace under DESTINATIONS: that team's repository can write
  into the other team's realm.
- Anything under CLUSTER: that team's repository may create cluster-scoped objects of those
  kinds.

A `namespaceResourceBlacklist` is not needed for Keycloak: the platform kinds are refused
by the guard for every identity (R3.1, R4.1), and Roles or RoleBindings from a repository
can only affect the team's own namespace (R8).

### R2.7 No group holds admin, edit or view cluster-wide

A ClusterRoleBinding to one of these roles is cluster-wide realm access, because the
Keycloak kinds are aggregated into them: `view` reads every realm definition, `edit` and
`admin` create cluster-scoped realms.

```bash
oc get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="admin" or .roleRef.name=="edit" or .roleRef.name=="view") | "\(.metadata.name): \(.roleRef.name) -> \([.subjects[]? | "\(.kind)/\(.name)"] | join(", "))"'
```

- Only platform service accounts (`klusterlet-work-sa`, `template-instance-controller`,
  `template-instance-finalizer-controller`): as expected.
- A `Group/` or `User/` line: that group or user can read, or write, every realm from any
  namespace. Remove the binding or accept it knowingly.

## R3. Admin credentials only where the operator runs; no tenant connections

### R3.1 Nobody creates a namespaced KeycloakInstance outside the operator namespace

A `KeycloakInstance` is a connection to a Keycloak server with its own credentials.

```bash
oc $E auth can-i create keycloakinstances -n guard-test-a
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

- `yes`, then a `ValidatingAdmissionPolicy` refusal, "managed by the platform team": RBAC
  would allow it, the platform-kinds guard is the control. The `yes` is expected.
- `created (server dry run)`: tenants can add their own Keycloak connections. The guard is
  missing or not bound here.

### R3.2 A tenant cannot reach the admin Secret or the operator

```bash
oc $A auth can-i get secrets -n $OPNS
oc $A auth can-i create pods/exec -n $OPNS
oc $A auth can-i create serviceaccounts/token -n $OPNS
oc $A auth can-i list secrets
```

- `no` on all four: no read of the admin password, no shell in the operator, no token with
  the operator's rights, no cluster-wide secret listing.
- `yes` on any: that path leads to the Keycloak admin login. Find the binding that grants it.

### R3.3 A tenant cannot create or read cluster-scoped instances

```bash
for v in get create; do printf "%-8s" $v; oc $A auth can-i $v clusterkeycloakinstances; done
```

- `no`, `no`: cluster-scoped kinds are out of reach through namespaced bindings.
- `yes`: the tenant's admin group holds something cluster-wide. See R2.7.

### R3.4 The cluster-scoped instance can read a Secret in any namespace

A `ClusterKeycloakInstance` names its credential Secret with a namespace. Whoever can
create one can make the operator read any Secret in the cluster and send it to any URL.
That is cluster admins and the infra Argo controller, so the platform repository is the
boundary.

```bash
oc get crd clusterkeycloakinstances.keycloak.hostzero.com -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.auth.properties.passwordGrant.properties.secretRef.properties}' | jq keys
oc get applications -n openshift-gitops -o custom-columns='NAME:.metadata.name,REPO:.spec.source.repoURL'
```

- `namespace` among the keys: the reach is as described; review on the platform repository
  is the control.
- Every Application in the infra instance points at a platform-owned repository: nothing
  untrusted can bring a `ClusterKeycloakInstance` in.
- A tenant repository in that list: that repository can read any Secret in the cluster.

## R4. Realms are a platform action

### R4.1 Nobody creates a namespaced KeycloakRealm outside the operator namespace

A namespaced `KeycloakRealm` pointing at the platform's instance with another realm's name
takes that realm over with the platform's admin login, master included. RBAC allows the
kind for every namespace admin; the platform-kinds guard is the only control.

```bash
oc $E auth can-i create keycloakrealms -n guard-test-a
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

- `yes`, then a `ValidatingAdmissionPolicy` refusal, "managed by the platform team": the
  guard holds. The `yes` is expected and is the reason the guard must never be removed.
- `created (server dry run)`: every project admin in the cluster can take over every realm.
  Stop and restore the guard before anything else.

### R4.2 A tenant cannot create, read, change or delete cluster-scoped realms

```bash
for v in get list create patch delete; do printf "%-8s" $v; oc $A auth can-i $v clusterkeycloakrealms; done
```

- `no` on all five: realm settings, creation and deletion stay with the platform.
- `yes` on `get` or `list`: the tenant reads every realm's definition. `yes` on the rest:
  the tenant can change or delete realms. Either means a cluster-wide binding; see R2.7.

## R5. Onboarding without per-tenant code

Covered by the onboarding ApplicationSet. After a tenant is onboarded:

```bash
oc get ns -l keycloak/tenant --show-labels
oc get clusterkeycloakrealm
```

- Every namespace of the tenant carries `keycloak/tenant=<realm>` and one
  `ClusterKeycloakRealm` with that name exists: onboarding produced the complete set.
- A namespace of the tenant without the label: objects there will be refused as not
  onboarded (R2.2).
- A realm without any labelled namespace: nobody can fill it.

## R6. Day-2 behaviour

Deleting an object removes it from Keycloak; the `keycloak.hostzero.com/preserve-resource`
annotation keeps it; removing a namespace's label while objects remain still lets them be
deleted. These need real objects and a real realm, so they are not part of the dry-run set;
they need a test run with real objects in a tenant namespace.

## R7. The guards exist, fail closed, and cover every namespace except the operator's

```bash
oc get validatingadmissionpolicy -o custom-columns='NAME:.metadata.name,FAIL:.spec.failurePolicy'
oc get validatingadmissionpolicybinding -o yaml | grep -E "name:|validationActions|values:|operator:|key:"
```

- Two policies with `Fail`; each binding with `Deny`; the namespace selector excludes
  exactly `$OPNS`: the guards refuse when they cannot evaluate, they reject rather than
  warn, and only the operator namespace is outside them.
- `Ignore` on a policy: an outage of the policy machinery silently lets everything through.
- `Warn` or `Audit` without `Deny`: the guard logs and lets the request through.
- A selector that excludes more than the operator namespace: those namespaces are
  unguarded, and R2.2 and R4.1 fail there.

Re-check this after every change to the platform repository. R4.1 shows why: this is the
only thing between a project admin and any realm.

## R8. Tenants cannot pass rights beyond their own namespace

Tenants hold `admin`, so they can create Roles and RoleBindings. The API server's
escalation check keeps that inside the namespace and below what they already hold.

```bash
oc $A create rolebinding share -n guard-test-a --clusterrole=edit --group=system:authenticated --dry-run=server
oc $A create rolebinding share -n guard-test-b --clusterrole=edit --group=system:authenticated --dry-run=server
oc $A create rolebinding esc -n guard-test-a --clusterrole=cluster-admin --group=team-a-admin --dry-run=server
```

- `created (server dry run)`, `Forbidden`, `Forbidden`: a tenant can share its own
  namespace with anyone, and that is accepted, since what they share stays inside their own
  realm. They cannot bind in another namespace, and cannot bind a role larger than their own.
- `created` on the second line: the tenant's admin group has rights in another tenant's
  namespace; find the binding.
- `created` on the third line: the group holds `bind` or `escalate`; it can grant itself
  anything.

## R9. The tenant controller holds nothing cluster-wide

The controller applies every tenant repository. Cluster-wide rights on it would let any
repository move namespaces between realms or create realms.

```bash
for r in "patch namespaces" "create namespaces" "patch projects" "create clusterkeycloakrealms" "create clusterrolebindings" "list namespaces"; do printf "%-32s" "$r"; oc auth can-i $r --as=$SA; done
```

- `no` on every line: the controller is bound per managed namespace only.
- `yes` on namespaces or projects: a tenant repository can change the realm label of any
  namespace. `yes` on clusterkeycloakrealms: a tenant repository can create realms. Find
  the ClusterRoleBinding that grants it.

## R10. The operator version and its roles are known and documented

### R10.1 The operator version

```bash
oc get csv -A | grep -i hostzero
```

Record the version. The kinds the tests use, and the roles below, follow from it.

### R10.2 Where the tenants' Keycloak rights come from

```bash
oc get clusterrole -l rbac.authorization.k8s.io/aggregate-to-admin=true | grep -E "hostzero|keycloak"
```

- One `<kind>.keycloak.hostzero.com-v1beta1-admin` per Hostzero kind, platform kinds
  included: the OLM install aggregates everything into `admin` (and likewise into `edit`
  and `view`). The team's own `keycloak-realm-admin` in the same list is a subset of that
  and controls nothing on its own. This is why R2.2, R3.1 and R4.1 answer `yes` on `can-i`
  and rely on the guards.
- `keycloaks.k8s.keycloak.org` and `keycloakrealmimports` in the list: the RHBK operator's
  kinds are aggregated the same way, so any project admin can deploy a Keycloak server in
  their namespace. Decide whether that is intended.

## Clean up

```bash
oc delete ns guard-test-a guard-test-b guard-test-c
```

Everything the setup created lives in these namespaces, including the binding the GitOps
operator added. Nothing cluster-scoped was created.

## Results

| Test | Expected | Result | Date |
|---|---|---|---|
| Canaries | `yes` for all five identities | | |
| R1.1 editors/admins create realm content | `yes`, `yes`, `created (server dry run)` | | |
| R1.2 viewers read only, no secrets | `yes`, `no`, `no` | | |
| R2.1 other realm and master refused | guard: "must be team-a in this namespace" | | |
| R2.2 unlabelled namespace refused | `yes`, then guard: "is not onboarded" | | |
| R2.3 realmRef refused | guard refusal mentioning `realmRef` | | |
| R2.4 indirect refs cannot name a namespace | `unknown field "spec.clientRef.namespace"` | | |
| R2.5 tenant cannot change the label | `Forbidden`, `field is immutable`, `Forbidden` | | |
| R2.6 AppProject destinations per team | own namespaces only, CLUSTER empty | | |
| R2.7 no cluster-wide admin/edit/view groups | platform service accounts only, no Group/ or User/ | | |
| R3.1 namespaced KeycloakInstance refused | `yes`, then guard: "managed by the platform team" | | |
| R3.2 admin Secret and operator out of reach | `no` on all four | | |
| R3.3 cluster instances out of reach | `no`, `no` | | |
| R3.4 instance secretRef reach, infra repositories | `namespace` in keys; only platform repositories | | |
| R4.1 namespaced KeycloakRealm refused | `yes`, then guard: "managed by the platform team" | | |
| R4.2 cluster realms out of reach | `no` on all five | | |
| R5 onboarding objects | every tenant namespace labelled, one realm | | |
| R7 guards fail closed, cover all namespaces | `Fail` on both, `Deny`, selector excludes only `$OPNS` | | |
| R8 sharing inside namespace only | `created`, `Forbidden`, `Forbidden` | | |
| R9 controller nothing cluster-wide | `no` on every line | | |
| R10.1 operator version | version recorded | | |
| R10.2 aggregated roles | one `-admin` role per Hostzero kind; RHBK decision noted | | |
