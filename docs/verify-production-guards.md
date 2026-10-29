# Verify the admission guards on the production cluster

Everything checked on 2026-10-29 was RBAC. These commands check the admission layer: that
the realm guard and the platform-kinds guard exist and act. Every request is a server-side
dry-run: RBAC and admission run, nothing is written.

Run them as yourself (cluster admin), **without `--as`**. RBAC runs before admission, so an
identity without rights would be refused by RBAC and the guard would never be seen. The
guards apply to cluster admins too, so a refusal that names a `ValidatingAdmissionPolicy`
is the proof.

## 0. Do the guards exist?

```bash
oc get validatingadmissionpolicy,validatingadmissionpolicybinding
```

Expected: two policies and two bindings, one pair for the realm guard and one for the
platform-kinds guard. Note the exact names; the tests below report them.

## 1. Set up two labelled namespaces

No tenant is onboarded yet, so create two namespaces with the realm label by hand. The
realms do not need to exist; the guards only compare the label with the reference.

```bash
oc create ns guard-test-a
oc create ns guard-test-b
oc label ns guard-test-a keycloak/tenant=team-a
oc label ns guard-test-b keycloak/tenant=team-b
```

## 2. The three tests

Instance name for test 1:

```bash
oc get clusterkeycloakinstance
```

### Test 1: a namespaced KeycloakRealm must be refused by the platform-kinds guard

Replace `<instansnamn>` with the name from the command above.

```bash
cat <<EOF | oc apply --dry-run=server -n guard-test-a -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakRealm
metadata:
  name: guard-check
spec:
  clusterInstanceRef:
    name: <instansnamn>
  realmName: guard-check
  definition: {}
EOF
```

Expected: an error that contains `ValidatingAdmissionPolicy '<platform-kinds guard>' ... denied request`.
If it says `created (server dry run)`, the guard is missing: every project admin in the
cluster can take over any realm, including master.

### Test 2: an object pointing at another realm must be refused by the realm guard

```bash
cat <<EOF | oc apply --dry-run=server -n guard-test-a -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: guard-check
spec:
  clusterRealmRef:
    name: team-b
  username: guard-check
EOF
```

Expected: an error that contains `ValidatingAdmissionPolicy '<realm guard>'` and says the
realm must be `team-a` in this namespace.

### Test 3: a namespace without the label must not reference any realm

```bash
cat <<EOF | oc apply --dry-run=server -n kafka-cluster -f -
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: guard-check
spec:
  clusterRealmRef:
    name: team-a
  username: guard-check
EOF
```

Expected: an error that contains `ValidatingAdmissionPolicy '<realm guard>'` and says the
namespace is not onboarded (label missing).

## 3. The open question: can a project admin change the label through the project API?

Needs a user who is admin in a project without the label (for example through its group).
Still a dry-run, nothing changes.

```bash
oc --as=<user> --as-group=<group> label project <project> keycloak/tenant=team-a --dry-run=server
```

Expected if the model holds: `Error from server (Forbidden)`. If it says
`labeled (server dry run)`, any project admin can point their namespace at any realm, and a
guard on namespace labels is needed.

## 4. Clean up

```bash
oc delete ns guard-test-a guard-test-b
```

## Results

| Test | Result | Date |
|---|---|---|
| 0 guards exist | | |
| 1 namespaced KeycloakRealm refused | | |
| 2 other realm refused | | |
| 3 unlabelled namespace refused | | |
| 3b project API label change refused | | |
