#!/usr/bin/env bash
# Verifies Keycloak tenant self-service (see README.md for the requirements)
# against a live cluster. Tenants are simulated with impersonation (--as), which
# goes through the same RBAC and admission chain as a real OIDC user.
#
# Usage: tests/run-tests.sh            (expects both charts installed)
set -uo pipefail

# Tenant editors get their rights through the OIDC group bound in their namespace.
T1=(--as=oidc-user:tenant1-dev@example.com --as-group=oidc-groups:tenant-1-editors)
T2=(--as=oidc-user:tenant2-dev@example.com --as-group=oidc-groups:tenant-2-editors)
NOGROUP=(--as=oidc-user:tenant1-dev@example.com)
API=keycloak.hostzero.com/v1beta1
KC_PORT=${KC_PORT:-18080}
PASS=0; FAIL=0; FAILED=()

ok()   { PASS=$((PASS+1)); printf '  \e[32mPASS\e[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \e[31mFAIL\e[0m %s\n     %s\n' "$1" "${2:-}"; }
section() { printf '\n\e[1m== %s\e[0m\n' "$1"; }

# expect_allow <desc> <cmd...>
expect_allow() {
  local d=$1; shift
  local out; if out=$("$@" 2>&1); then ok "$d"; else bad "$d" "$out"; fi
}
# expect_deny <desc> <regex the error must match> <cmd...>
expect_deny() {
  local d=$1 re=$2; shift 2
  local out; if out=$("$@" 2>&1); then bad "$d" "unexpectedly allowed: $out"
  elif grep -Eq "$re" <<<"$out"; then ok "$d  [$(grep -Eo "$re" <<<"$out" | head -1)]"
  else bad "$d" "denied for the wrong reason: $out"; fi
}
# apply manifest from stdin as given identity: kapply <ident-array-name> <<EOF
kapply() { kubectl "$@" apply -f - ; }

wait_ready() { # <kind> <name> <ns> [timeout]
  kubectl -n "$3" wait "$1/$2" --for=jsonpath='{.status.ready}'=true --timeout="${4:-60s}" >/dev/null 2>&1
}

# --- Keycloak admin API (platform side, to check where things really landed) ---
kubectl -n keycloak port-forward svc/keycloak "$KC_PORT":8080 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 30); do curl -fs "localhost:$KC_PORT/realms/master" >/dev/null && break; sleep 1; done
kc_token() {
  curl -fs "localhost:$KC_PORT/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin | jq -r .access_token
}
kc() { curl -fs -H "Authorization: Bearer $(kc_token)" "localhost:$KC_PORT/admin/realms/$1"; }
kc_has_user()   { kc "$1/users?username=$2&exact=true" | jq -e 'length==1' >/dev/null; }
kc_has_client() { kc "$1/clients?clientId=$2" | jq -e 'length==1' >/dev/null; }
kc_has_role()   { kc "$1/roles/$2" >/dev/null; }

cleanup() {
  kubectl delete ns lab-unonboarded --ignore-not-found --wait=false >/dev/null
  for ns in tenant-1 tenant-2; do
    kubectl -n $ns delete keycloakusercredentials,keycloakrolemappings,keycloakprotocolmappers,keycloakroles,keycloakusers,keycloakgroups,keycloakclients,keycloakcomponents -l lab-test=true --ignore-not-found --wait=true --timeout=60s >/dev/null
    kubectl -n $ns delete rolebinding oops-admin --ignore-not-found >/dev/null
    kubectl -n $ns delete secret -l lab-test=true --ignore-not-found >/dev/null
  done
}
cleanup


# =============================================================================
section "R1 tenant self-service: tenant-1 manages content in its own realm"

expect_allow "tenant-1 creates Secret with initial password" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: v1
kind: Secret
metadata: {name: alice-pw, labels: {lab-test: "true"}}
stringData: {username: alice, password: "S3cret-alice!"}
EOF
expect_allow "tenant-1 creates KeycloakUser alice in clusterRealmRef tenant-1" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakUser
metadata: {name: alice, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-1}
  username: alice
  definition: {enabled: true, email: alice@tenant1.example, emailVerified: true}
EOF
expect_allow "tenant-1 creates KeycloakUserCredential (userRef alice)" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakUserCredential
metadata: {name: alice-pw, labels: {lab-test: "true"}}
spec:
  userRef: {name: alice}
  userSecret: {secretName: alice-pw, usernameKey: username, passwordKey: password}
EOF
expect_allow "tenant-1 creates KeycloakClient app1 + KeycloakRole, Group, RoleMapping, ProtocolMapper" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakClient
metadata: {name: app1, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-1}
  clientId: app1
  definition: {enabled: true, publicClient: false, serviceAccountsEnabled: true}
  clientSecretRef: {name: app1-credentials, create: true}
---
apiVersion: $API
kind: KeycloakRole
metadata: {name: app1-reader, labels: {lab-test: "true"}}
spec:
  clientRef: {name: app1}
  name: reader
  definition: {description: read access}
---
apiVersion: $API
kind: KeycloakRole
metadata: {name: editor, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-1}
  name: editor
  definition: {description: editor}
---
apiVersion: $API
kind: KeycloakGroup
metadata: {name: devs, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-1}
  name: devs
  definition: {}
---
apiVersion: $API
kind: KeycloakGroup
metadata: {name: devs-backend, labels: {lab-test: "true"}}
spec:
  parentGroupRef: {name: devs}
  name: backend
  definition: {}
---
apiVersion: $API
kind: KeycloakRoleMapping
metadata: {name: alice-editor, labels: {lab-test: "true"}}
spec:
  subject: {userRef: {name: alice}}
  roleRef: {name: editor}
---
apiVersion: $API
kind: KeycloakProtocolMapper
metadata: {name: app1-dept, labels: {lab-test: "true"}}
spec:
  clientRef: {name: app1}
  name: department
  definition:
    protocol: openid-connect
    protocolMapper: oidc-usermodel-attribute-mapper
    config: {user.attribute: department, claim.name: dept, access.token.claim: "true"}
EOF

for r in keycloakuser/alice keycloakusercredential/alice-pw keycloakclient/app1 keycloakrole/app1-reader \
         keycloakrole/editor keycloakgroup/devs keycloakgroup/devs-backend keycloakrolemapping/alice-editor \
         keycloakprotocolmapper/app1-dept; do
  if wait_ready "${r%/*}" "${r#*/}" tenant-1 90s; then ok "$r is Ready"
  else bad "$r is Ready" "$(kubectl -n tenant-1 get "$r" -o jsonpath='{.status.message}')"; fi
done
kc_has_user tenant-1 alice && ok "Keycloak: alice exists in realm tenant-1" || bad "Keycloak: alice exists in realm tenant-1"
kc_has_client tenant-1 app1 && ok "Keycloak: client app1 exists in realm tenant-1" || bad "Keycloak: client app1 exists in realm tenant-1"
kubectl "${T1[@]}" -n tenant-1 get secret app1-credentials >/dev/null 2>&1 \
  && ok "tenant-1 can read its generated client secret" || bad "tenant-1 can read its generated client secret"
curl -fs "localhost:$KC_PORT/realms/tenant-1/protocol/openid-connect/token" -d grant_type=password \
  -d client_id=app1 -d client_secret="$(kubectl -n tenant-1 get secret app1-credentials -o jsonpath='{.data.client-secret}' | base64 -d)" \
  -d username=alice -d password='S3cret-alice!' -d scope=openid >/dev/null 2>&1 \
  || true # direct grants are off by default; credential is checked via the user's credentials list instead
kc "tenant-1/users/$(kc 'tenant-1/users?username=alice&exact=true' | jq -r '.[0].id')/credentials" | jq -e 'any(.type=="password")' >/dev/null \
  && ok "Keycloak: alice has a password credential" || bad "Keycloak: alice has a password credential"

expect_deny "same user without the tenant-1 group has no access" "forbidden" \
  kubectl "${NOGROUP[@]}" -n tenant-1 get keycloakusers
expect_deny "member of tenant-2 group has no access in tenant-1" "forbidden" \
  kubectl --as=oidc-user:someone --as-group=oidc-groups:tenant-2-editors -n tenant-1 get keycloakusers

# tenant-2 seeds a client so tenant-1 has something to aim at
kapply "${T2[@]}" -n tenant-2 >/dev/null <<EOF
apiVersion: $API
kind: KeycloakClient
metadata: {name: t2-app, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-2}
  clientId: t2-app
  definition: {enabled: true}
---
apiVersion: $API
kind: KeycloakUser
metadata: {name: bob, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-2}
  username: bob
---
apiVersion: $API
kind: KeycloakGroup
metadata: {name: t2-group, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-2}
  name: t2-group
  definition: {}
EOF
wait_ready keycloakclient t2-app tenant-2 90s && wait_ready keycloakuser bob tenant-2 90s \
  && ok "tenant-2 manages its own realm (t2-app, bob)" || bad "tenant-2 manages its own realm"

# =============================================================================
section "R2 realm isolation: admission guard"

user_in() { # <realm-ref-yaml> <name>
cat <<EOF
apiVersion: $API
kind: KeycloakUser
metadata: {name: $2, labels: {lab-test: "true"}}
spec:
  $1
  username: $2
EOF
}
expect_deny "tenant-1 -> clusterRealmRef tenant-2" "must be tenant-1" \
  kapply "${T1[@]}" -n tenant-1 < <(user_in "clusterRealmRef: {name: tenant-2}" evil1)
expect_deny "tenant-1 -> clusterRealmRef master" "must be tenant-1" \
  kapply "${T1[@]}" -n tenant-1 < <(user_in "clusterRealmRef: {name: master}" evil2)
expect_deny "tenant-1 -> namespaced realmRef" "realmRef \(namespaced realm\) is not allowed" \
  kapply "${T1[@]}" -n tenant-1 < <(user_in "realmRef: {name: tenant-2}" evil3)
for kind in KeycloakGroup KeycloakRole KeycloakClientScope KeycloakOrganization; do
  expect_deny "tenant-1 $kind -> clusterRealmRef tenant-2" "must be tenant-1" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: $API
kind: $kind
metadata: {name: evil-$(tr A-Z a-z <<<"$kind"), labels: {lab-test: "true"}}
spec: {clusterRealmRef: {name: tenant-2}, name: evil, definition: {name: evil}}
EOF
done
expect_deny "tenant-1 KeycloakClient -> clusterRealmRef tenant-2" "must be tenant-1" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakClient
metadata: {name: evil-client, labels: {lab-test: "true"}}
spec: {clusterRealmRef: {name: tenant-2}, clientId: evil}
EOF
expect_deny "tenant-1 KeycloakIdentityProvider -> clusterRealmRef tenant-2" "must be tenant-1" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakIdentityProvider
metadata: {name: evil-idp, labels: {lab-test: "true"}}
spec: {clusterRealmRef: {name: tenant-2}, alias: evil, definition: {providerId: oidc}}
EOF
expect_deny "tenant-1 moves existing alice to tenant-2 (patch)" "must be tenant-1" \
  kubectl "${T1[@]}" -n tenant-1 patch keycloakuser alice --type=merge -p '{"spec":{"clusterRealmRef":{"name":"tenant-2"}}}'
expect_deny "tenant-1 swaps alice to realmRef (json patch)" "realmRef|exactly|== 1|Invalid" \
  kubectl "${T1[@]}" -n tenant-1 patch keycloakuser alice --type=json \
  -p '[{"op":"remove","path":"/spec/clusterRealmRef"},{"op":"add","path":"/spec/realmRef","value":{"name":"x"}}]'
expect_deny "tenant-1 creates CR in namespace tenant-2 (RBAC)" "forbidden" \
  kapply "${T1[@]}" -n tenant-2 < <(user_in "clusterRealmRef: {name: tenant-2}" evil4)
expect_deny "tenant-1 reads tenant-2 secrets (RBAC)" "forbidden" kubectl "${T1[@]}" -n tenant-2 get secrets

section "R2 deny by default: namespace without tenant label"
kubectl create ns lab-unonboarded >/dev/null
expect_deny "cluster-admin in un-onboarded ns -> clusterRealmRef tenant-1" "is not onboarded" \
  kapply -n lab-unonboarded < <(user_in "clusterRealmRef: {name: tenant-1}" stray)
expect_deny "cluster-admin in un-onboarded ns -> realmRef" "realmRef \(namespaced realm\)" \
  kapply -n lab-unonboarded < <(user_in "realmRef: {name: anything}" stray2)
expect_deny "cluster-admin in tenant-1 ns -> clusterRealmRef tenant-2 (policy applies to admins too)" "must be tenant-1" \
  kapply -n tenant-1 < <(user_in "clusterRealmRef: {name: tenant-2}" stray3)

section "R2 indirect placement: refs resolve in own namespace only"
# t2-app, bob and t2-group exist only in namespace tenant-2.
hijack_manifests() {
cat <<EOF
apiVersion: $API
kind: KeycloakRole
metadata: {name: hijack-role, labels: {lab-test: "true"}}
spec: {clientRef: {name: t2-app, namespace: tenant-2}, name: hijacked, definition: {}}
---
apiVersion: $API
kind: KeycloakUser
metadata: {name: hijack-sa, labels: {lab-test: "true"}}
spec: {clientRef: {name: t2-app, namespace: tenant-2}}
---
apiVersion: $API
kind: KeycloakGroup
metadata: {name: hijack-group, labels: {lab-test: "true"}}
spec: {parentGroupRef: {name: t2-group, namespace: tenant-2}, name: hijacked, definition: {}}
---
apiVersion: $API
kind: KeycloakUserCredential
metadata: {name: hijack-cred, labels: {lab-test: "true"}}
spec: {userRef: {name: bob, namespace: tenant-2}, userSecret: {secretName: alice-pw, usernameKey: username, passwordKey: password}}
---
apiVersion: $API
kind: KeycloakProtocolMapper
metadata: {name: hijack-mapper, labels: {lab-test: "true"}}
spec:
  clientRef: {name: t2-app, namespace: tenant-2}
  name: hijacked
  definition: {protocol: openid-connect, protocolMapper: oidc-hardcoded-claim-mapper, config: {claim.name: pwned, claim.value: "1"}}
---
apiVersion: $API
kind: KeycloakRoleMapping
metadata: {name: hijack-mapping, labels: {lab-test: "true"}}
spec:
  subject: {userRef: {name: bob, namespace: tenant-2}}
  role: {name: admin, clientId: realm-management}
EOF
}
expect_deny "cross-namespace ref with explicit namespace is rejected (strict field validation)" "unknown field" \
  kapply "${T1[@]}" -n tenant-1 < <(hijack_manifests)
# Same objects without client-side/server-side strictness: unknown fields are pruned,
# so the refs resolve by name in tenant-1, where t2-app, bob and t2-group do not exist.
kapply "${T1[@]}" -n tenant-1 --validate=false >/dev/null 2>&1 < <(hijack_manifests)
sleep 10
for r in keycloakrole/hijack-role keycloakuser/hijack-sa keycloakgroup/hijack-group keycloakusercredential/hijack-cred \
         keycloakprotocolmapper/hijack-mapper keycloakrolemapping/hijack-mapping; do
  ns_field=$(kubectl -n tenant-1 get "$r" -o json 2>/dev/null | jq -r '[.spec|..|objects|select(has("namespace"))]|length')
  ready=$(kubectl -n tenant-1 get "$r" -o jsonpath='{.status.ready}' 2>/dev/null)
  msg=$(kubectl -n tenant-1 get "$r" -o jsonpath='{.status.message}' 2>/dev/null)
  if [ -n "$ready$msg" ] && [ "$ns_field" = 0 ] && [ "$ready" != true ]; then ok "$r: 'namespace' pruned, not resolved [$msg]"
  else bad "$r: cross-namespace ref must not resolve" "namespace-fields=$ns_field ready=$ready msg=$msg"; fi
done
T2APP=$(kc "tenant-2/clients?clientId=t2-app" | jq -r '.[0].id')
kc "tenant-2/clients/$T2APP/roles" | jq -e 'any(.name=="hijacked")' >/dev/null \
  && bad "Keycloak: no role 'hijacked' on tenant-2 client" || ok "Keycloak: no role 'hijacked' on tenant-2 client"
kc "tenant-2/clients/$T2APP/protocol-mappers/models" | jq -e 'any(.name=="hijacked")' >/dev/null \
  && bad "Keycloak: no mapper 'hijacked' on tenant-2 client" || ok "Keycloak: no mapper 'hijacked' on tenant-2 client"
BOB=$(kc 'tenant-2/users?username=bob&exact=true' | jq -r '.[0].id')
kc "tenant-2/users/$BOB/credentials" | jq -e 'length==0' >/dev/null \
  && ok "Keycloak: bob (tenant-2) got no password from tenant-1" || bad "Keycloak: bob (tenant-2) got no password from tenant-1"
kc "tenant-2/users/$BOB/role-mappings" | jq -e '.clientMappings["realm-management"]' >/dev/null \
  && bad "Keycloak: bob got no realm-management roles" || ok "Keycloak: bob got no realm-management roles"

section "R2 smuggling through spec.definition (free-form)"
T2ID=$(kc tenant-2 | jq -r .id)
kapply "${T1[@]}" -n tenant-1 >/dev/null 2>&1 <<EOF
apiVersion: $API
kind: KeycloakComponent
metadata: {name: smuggle-parent, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-1}
  name: smuggled-key
  definition:
    parentId: "$T2ID"
    providerId: rsa-generated
    providerType: org.keycloak.keys.KeyProvider
    config: {priority: ["1"]}
---
apiVersion: $API
kind: KeycloakUser
metadata: {name: smuggle-user, labels: {lab-test: "true"}}
spec:
  clusterRealmRef: {name: tenant-1}
  username: smuggle
  definition: {realm: tenant-2, origin: tenant-2}
EOF
sleep 10
kc "tenant-2/components?name=smuggled-key" | jq -e 'length==0' >/dev/null \
  && ok "component with definition.parentId=<tenant-2 id> did not land in tenant-2 [$(kubectl -n tenant-1 get keycloakcomponent smuggle-parent -o jsonpath='{.status.status}')]" \
  || bad "component with definition.parentId=<tenant-2 id> landed in tenant-2!"
kc_has_user tenant-2 smuggle && bad "user with definition.realm=tenant-2 landed in tenant-2!" \
  || ok "user with definition.realm=tenant-2 did not land in tenant-2"

# =============================================================================
section "R3 no admin credentials in tenant hands"
expect_deny "tenant-1 reads admin secret" "forbidden" \
  kubectl "${T1[@]}" -n keycloak-operator get secret keycloak-ocp-01-admin
expect_deny "tenant-1 lists secrets cluster-wide" "forbidden" kubectl "${T1[@]}" get secrets -A
expect_deny "tenant-1 creates KeycloakInstance in own ns" "forbidden" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakInstance
metadata: {name: own-conn}
spec: {baseUrl: http://keycloak.keycloak.svc:8080, auth: {passwordGrant: {secretRef: {name: alice-pw}}}}
EOF
expect_deny "tenant-1 creates ClusterKeycloakInstance" "forbidden" kapply "${T1[@]}" <<EOF
apiVersion: $API
kind: ClusterKeycloakInstance
metadata: {name: own-conn}
spec: {baseUrl: http://keycloak.keycloak.svc:8080, auth: {passwordGrant: {secretRef: {name: keycloak-ocp-01-admin, namespace: keycloak-operator}}}}
EOF
expect_deny "tenant-1 execs into operator pod" "forbidden" \
  kubectl "${T1[@]}" -n keycloak-operator exec deploy/keycloak-operator -- true

# =============================================================================
section "R4 realm lifecycle stays with the platform"
expect_deny "tenant-1 creates ClusterKeycloakRealm" "forbidden" kapply "${T1[@]}" <<EOF
apiVersion: $API
kind: ClusterKeycloakRealm
metadata: {name: tenant-1-extra}
spec: {clusterInstanceRef: {name: ocp-01}, realmName: tenant-1-extra}
EOF
expect_deny "tenant-1 patches its ClusterKeycloakRealm" "forbidden" \
  kubectl "${T1[@]}" patch clusterkeycloakrealm tenant-1 --type=merge -p '{"spec":{"definition":{"registrationAllowed":true}}}'
expect_deny "tenant-1 deletes its ClusterKeycloakRealm" "forbidden" kubectl "${T1[@]}" delete clusterkeycloakrealm tenant-1
expect_deny "tenant-1 creates namespaced KeycloakRealm" "forbidden" kapply "${T1[@]}" -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakRealm
metadata: {name: own-realm}
spec: {clusterInstanceRef: {name: ocp-01}, realmName: own-realm}
EOF
# A namespaced KeycloakRealm pointing at the platform instance could create a
# realm, or take over an existing one, with the platform's admin login. Checked
# as cluster-admin to stand in for any broad identity, such as a GitOps controller.
expect_deny "cluster-admin: KeycloakRealm in tenant-1 taking over realm tenant-2" "managed by the platform team" kapply -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakRealm
metadata: {name: takeover}
spec: {clusterInstanceRef: {name: ocp-01}, realmName: tenant-2, definition: {displayName: PWNED}}
EOF
expect_deny "cluster-admin: KeycloakRealm for master in un-onboarded ns" "managed by the platform team" kapply -n lab-unonboarded <<EOF
apiVersion: $API
kind: KeycloakRealm
metadata: {name: takeover-master}
spec: {clusterInstanceRef: {name: ocp-01}, realmName: master, definition: {enabled: true}}
EOF
expect_deny "cluster-admin: KeycloakInstance in tenant-1" "managed by the platform team" kapply -n tenant-1 <<EOF
apiVersion: $API
kind: KeycloakInstance
metadata: {name: own-conn}
spec: {baseUrl: http://keycloak.keycloak.svc:8080, auth: {passwordGrant: {secretRef: {name: x}}}}
EOF
[ "$(kc tenant-2 | jq -r .displayName)" = "Tenant 2" ] && ok "Keycloak: realm tenant-2 untouched" || bad "Keycloak: realm tenant-2 untouched"
expect_deny "tenant-1 relabels its namespace to tenant-2" "forbidden" \
  kubectl "${T1[@]}" label ns tenant-1 keycloak.lab/tenant-realm=tenant-2 --overwrite
expect_deny "tenant-1 creates a new namespace" "forbidden" \
  kubectl "${T1[@]}" create ns sneaky
expect_deny "tenant-1 deletes its namespace" "forbidden" kubectl "${T1[@]}" delete ns tenant-1 --wait=false

# =============================================================================
section "R8 no RBAC changes by tenants"
expect_deny "tenant-1 (edit) creates RoleBinding" "forbidden" \
  kubectl "${T1[@]}" -n tenant-1 create rolebinding share --role=keycloak-realm-editor --group=system:authenticated
expect_deny "tenant-1 (edit) deletes keycloak-realm-editors" "forbidden" \
  kubectl "${T1[@]}" -n tenant-1 delete rolebinding keycloak-realm-editors
expect_deny "tenant-1 (edit) creates ServiceAccount token for operator SA" "forbidden|not found" \
  kubectl "${T1[@]}" -n keycloak-operator create token keycloak-operator

echo "  -- simulate a mistake: platform binds built-in 'admin' to tenant-1 --"
kubectl -n tenant-1 create rolebinding oops-admin --clusterrole=admin --group=oidc-groups:tenant-1-editors >/dev/null \
  && ok "platform identity may still change RBAC in tenant ns (exempt)" || bad "platform identity may change RBAC in tenant ns"
expect_deny "tenant-1 (admin) creates RoleBinding to system:authenticated" "managed by the platform team" \
  kubectl "${T1[@]}" -n tenant-1 create rolebinding share --role=keycloak-realm-editor --group=system:authenticated
expect_deny "tenant-1 (admin) creates Role" "managed by the platform team" \
  kubectl "${T1[@]}" -n tenant-1 create role extra --verb=get --resource=pods
expect_deny "tenant-1 (admin) adds subject to keycloak-realm-editors" "managed by the platform team" \
  kubectl "${T1[@]}" -n tenant-1 patch rolebinding keycloak-realm-editors --type=json \
  -p '[{"op":"add","path":"/subjects/-","value":{"kind":"Group","name":"system:authenticated","apiGroup":"rbac.authorization.k8s.io"}}]'
expect_deny "tenant-1 (admin) deletes keycloak-realm-editors" "managed by the platform team" \
  kubectl "${T1[@]}" -n tenant-1 delete rolebinding keycloak-realm-editors
expect_deny "tenant-1 (admin) deletes its own oops-admin binding" "managed by the platform team" \
  kubectl "${T1[@]}" -n tenant-1 delete rolebinding oops-admin
expect_deny "tenant-1 (admin) widens Role keycloak-realm-editor" "managed by the platform team" \
  kubectl "${T1[@]}" -n tenant-1 patch role keycloak-realm-editor --type=json \
  -p '[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["pods"],"verbs":["get"]}}]'
expect_deny "tenant-1 (admin) still cannot target tenant-2 realm" "must be tenant-1" \
  kapply "${T1[@]}" -n tenant-1 < <(user_in "clusterRealmRef: {name: tenant-2}" evil5)
expect_deny "tenant-1 (admin) cannot relabel namespace" "forbidden" \
  kubectl "${T1[@]}" label ns tenant-1 keycloak.lab/tenant-realm=tenant-2 --overwrite
kubectl -n tenant-1 delete rolebinding oops-admin >/dev/null

# =============================================================================
section "R6 day-2: delete and preserve"
kubectl "${T1[@]}" -n tenant-1 delete keycloakuser alice --wait=true --timeout=60s >/dev/null 2>&1
kc_has_user tenant-1 alice && bad "deleting KeycloakUser alice removes it from Keycloak" \
  || ok "deleting KeycloakUser alice removes it from Keycloak"
kapply "${T1[@]}" -n tenant-1 >/dev/null <<EOF
apiVersion: $API
kind: KeycloakUser
metadata:
  name: carol
  labels: {lab-test: "true"}
  annotations: {keycloak.hostzero.com/preserve-resource: "true"}
spec: {clusterRealmRef: {name: tenant-1}, username: carol}
EOF
wait_ready keycloakuser carol tenant-1 60s
kubectl "${T1[@]}" -n tenant-1 delete keycloakuser carol --wait=true --timeout=60s >/dev/null 2>&1
kc_has_user tenant-1 carol && ok "preserve-resource annotation keeps carol in Keycloak" \
  || bad "preserve-resource annotation keeps carol in Keycloak"

echo "  -- offboarding: platform removes the tenant label before the CRs are gone --"
kubectl create ns lab-offboard >/dev/null; kubectl label ns lab-offboard keycloak.lab/tenant-realm=tenant-2 >/dev/null
kapply -n lab-offboard >/dev/null < <(user_in "clusterRealmRef: {name: tenant-2}" dave)
wait_ready keycloakuser dave lab-offboard 60s
kubectl label ns lab-offboard keycloak.lab/tenant-realm- >/dev/null
expect_deny "offboarded ns: spec change is denied" "is not onboarded" \
  kubectl -n lab-offboard patch keycloakuser dave --type=merge -p '{"spec":{"definition":{"firstName":"D"}}}'
if kubectl -n lab-offboard delete keycloakuser dave --timeout=60s >/dev/null 2>&1; then
  ok "offboarded ns: CR deletion completes (finalizer removal not blocked)"
else bad "offboarded ns: CR deletion completes" "stuck with finalizers $(kubectl -n lab-offboard get keycloakuser dave -o jsonpath='{.metadata.finalizers}')"; fi
kc_has_user tenant-2 dave && bad "offboarded ns: dave removed from Keycloak" || ok "offboarded ns: dave removed from Keycloak"
kubectl delete ns lab-offboard --wait=false >/dev/null

# =============================================================================
cleanup
printf '\n\e[1mResult: %d passed, %d failed\e[0m\n' "$PASS" "$FAIL"
for f in "${FAILED[@]}"; do echo "  - $f"; done
[ "$FAIL" -eq 0 ]
