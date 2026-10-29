#!/usr/bin/env bash
# Runs every test in docs/production-coverage.md against the cluster oc points at, and
# prints the results table. Every write is a server-side dry-run; the only things created
# are three guard-test-* namespaces, removed on exit.
#
# Two kinds of failure:
#   - a test gives an unexpected answer: the row says FAIL, the run continues;
#   - the tests cannot run at all (not logged in, no instance, a namespace could not be
#     created, an identity's canary fails): the run stops, cleans up, exits 2.
#
# Input: the namespace of the tenant Argo CD instance (asked for, or ARGONS=... in the
# environment). Optional: OC=kubectl to use kubectl, LABEL=<key> for another label key,
# BIND_CONTROLLER=1 to bind the controller in the test namespace yourself when no GitOps
# operator reacts to the managed-by label.

set -u

OC=${OC:-oc}
LABEL=${LABEL:-keycloak/tenant}
NSA=guard-test-a
NSB=guard-test-b
NSC=guard-test-c
TODAY=$(date +%F)

# --- output ------------------------------------------------------------------------------

ROWS=()                  # "ID|description|expected|result"
CURRENT_ID=""; CURRENT_DESC=""; CURRENT_EXPECTED=""; CURRENT_FAIL=""; STEP=0

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "----------------------------------------------------------------------"; }

fatal() {
  say ""
  say "FATAL: $*"
  say "The tests cannot run. Cleaning up and stopping."
  exit 2
}

begin() {                # begin ID "description" "expected"
  CURRENT_ID=$1; CURRENT_DESC=$2; CURRENT_EXPECTED=$3; CURRENT_FAIL=""; STEP=0
}

# the most telling line of an error: the last non-empty one (kubectl puts the reason last)
first_line() { printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-160; }

# expect PATTERN cmd...   the command's output (stdout+stderr) must match the regex
expect() {
  local pattern=$1; shift
  STEP=$((STEP + 1))
  local out; out=$("$@" 2>&1)
  if ! printf '%s\n' "$out" | grep -Eq -- "$pattern"; then
    [ -z "$CURRENT_FAIL" ] && CURRENT_FAIL="step $STEP: expected /$pattern/, got: $(first_line "$out")"
  fi
}

# expect_absent PATTERN cmd...   the output must NOT match the regex
expect_absent() {
  local pattern=$1; shift
  STEP=$((STEP + 1))
  local out; out=$("$@" 2>&1)
  if printf '%s\n' "$out" | grep -Eq -- "$pattern"; then
    [ -z "$CURRENT_FAIL" ] && CURRENT_FAIL="step $STEP: found /$pattern/: $(printf '%s\n' "$out" | grep -E -- "$pattern" | head -n 1 | cut -c1-110)"
  fi
}

# expect_apply PATTERN "identity args" namespace  <<EOF yaml EOF
expect_apply() {
  local pattern=$1 ident=$2 ns=$3
  STEP=$((STEP + 1))
  # --validate=strict: the server must reject unknown fields rather than prune them silently;
  # older oc clients do not ask for that by default, and R2.4 depends on it.
  local out; out=$($OC $ident apply --dry-run=server --validate=strict -n "$ns" -f - 2>&1)
  if ! printf '%s\n' "$out" | grep -Eq -- "$pattern"; then
    [ -z "$CURRENT_FAIL" ] && CURRENT_FAIL="step $STEP: expected /$pattern/, got: $(first_line "$out")"
  fi
}

end() {                  # closes the current test and prints its row
  local result
  if [ -z "$CURRENT_FAIL" ]; then result="PASS"; else result="FAIL  $CURRENT_FAIL"; fi
  printf '%-7s %-4s %s\n' "$CURRENT_ID" "${result%% *}" "$CURRENT_DESC"
  [ -n "$CURRENT_FAIL" ] && printf '        %s\n' "$CURRENT_FAIL"
  ROWS+=("$CURRENT_ID|$CURRENT_DESC|$CURRENT_EXPECTED|${result%% *}${CURRENT_FAIL:+: $CURRENT_FAIL}")
}

# review ID "description" "what to look for" cmd...   prints the output for a human
review() {
  local id=$1 desc=$2 expected=$3; shift 3
  printf '%-7s %-4s %s\n' "$id" "REVW" "$desc"
  printf '        look for: %s\n' "$expected"
  "$@" 2>&1 | sed 's/^/        | /'
  ROWS+=("$id|$desc|$expected|REVIEW")
}

skip() {                 # skip ID "description" "expected" "why"
  printf '%-7s %-4s %s (%s)\n' "$1" "SKIP" "$2" "$4"
  ROWS+=("$1|$2|$3|SKIP: $4")
}

# --- cleanup, always ---------------------------------------------------------------------

cleanup() {
  say ""
  say "Cleaning up guard-test namespaces"
  $OC delete ns "$NSA" "$NSB" "$NSC" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- preflight ---------------------------------------------------------------------------

command -v "$OC" >/dev/null || fatal "$OC not found"
command -v jq >/dev/null    || fatal "jq not found"
$OC auth whoami >/dev/null 2>&1 || fatal "not logged in ($OC auth whoami failed)"
[ "$($OC auth can-i '*' '*' 2>/dev/null)" = "yes" ] || fatal "the tests impersonate other identities, which needs cluster-admin"

if [ -z "${ARGONS:-}" ]; then
  read -rp "Namespace of the tenant Argo CD instance (developer-gitops): " ARGONS
fi
[ -n "$ARGONS" ] || fatal "no Argo CD namespace given"
$OC get ns "$ARGONS" >/dev/null 2>&1 || fatal "namespace $ARGONS does not exist"

SA=system:serviceaccount:$ARGONS:developer-gitops-argocd-application-controller
INSTANCE=$($OC get clusterkeycloakinstance -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$INSTANCE" ] || fatal "no ClusterKeycloakInstance in the cluster"
OPNS=$($OC get clusterkeycloakinstance "$INSTANCE" -o jsonpath='{.spec.auth.passwordGrant.secretRef.namespace}' 2>/dev/null)
[ -n "$OPNS" ] || fatal "ClusterKeycloakInstance $INSTANCE has no secretRef.namespace"

HAS_PROJECT_API=0
$OC api-resources --api-group=project.openshift.io 2>/dev/null | grep -q '^projects ' && HAS_PROJECT_API=1

hr
say "cluster:    $($OC whoami --show-server 2>/dev/null || $OC config current-context)"
say "as:         $($OC auth whoami -o jsonpath='{.status.userInfo.username}')"
say "controller: $SA"
say "instance:   $INSTANCE   operator namespace: $OPNS   label: $LABEL"
say "date:       $TODAY"
hr

# --- setup -------------------------------------------------------------------------------

say "Setup"
for ns in "$NSA" "$NSB" "$NSC"; do
  $OC create ns "$ns" >/dev/null 2>&1 || fatal "could not create namespace $ns (left over from an earlier run? delete it first)"
done
$OC label ns "$NSA" "$LABEL=team-a" "argocd.argoproj.io/managed-by=$ARGONS" >/dev/null || fatal "could not label $NSA"
$OC label ns "$NSB" "$LABEL=team-b" >/dev/null || fatal "could not label $NSB"
for r in admin edit view; do
  $OC create rolebinding "tenant-$r" -n "$NSA" --clusterrole="$r" --group="team-a-$r" >/dev/null || fatal "could not bind $r in $NSA"
done
$OC create rolebinding guard-test-admin -n "$NSC" --clusterrole=admin --group=guard-test-admins >/dev/null || fatal "could not bind admin in $NSC"

A="--as=team-a-user --as-group=team-a-admin"
E="--as=team-a-user --as-group=team-a-edit"
V="--as=team-a-user --as-group=team-a-view"
C="--as=other-user --as-group=guard-test-admins"
S="--as=$SA"

if [ "${BIND_CONTROLLER:-0}" = "1" ]; then
  $OC create rolebinding argocd-application-controller -n "$NSA" --clusterrole=admin \
    --serviceaccount="$ARGONS:developer-gitops-argocd-application-controller" >/dev/null || fatal "could not bind the controller in $NSA"
else
  printf 'waiting for the GitOps operator to bind the controller in %s ' "$NSA"
  for _ in $(seq 1 45); do
    [ "$($OC $S auth can-i create pods -n "$NSA" 2>/dev/null)" = "yes" ] && break
    printf '.'; sleep 2
  done
  say ""
fi

# --- canaries (fatal) --------------------------------------------------------------------

say "Canaries"
canary() {               # canary "who" ident verb resource namespace
  local who=$1 ident=$2 verb=$3 res=$4 ns=$5
  local got; got=$($OC $ident auth can-i "$verb" "$res" -n "$ns" 2>&1)
  if [ "$got" = "yes" ]; then printf '  %-28s yes\n' "$who"
  else fatal "canary for $who: $verb $res in $ns gave '$got' (identity mistyped, or binding missing)"; fi
}
canary "tenant admin"     "$A" create pods "$NSA"
canary "tenant editor"    "$E" create pods "$NSA"
canary "tenant viewer"    "$V" list   pods "$NSA"
canary "other project admin" "$C" create pods "$NSC"
canary "tenant controller" "$S" create pods "$NSA"
ROWS+=("Canaries|all five identities resolve|yes for all five|PASS")

# --- tests -------------------------------------------------------------------------------

hr; say "R1  Tenants manage everything inside their realm"

begin R1.1 "editors/admins create realm content" "yes, yes, created (server dry run)"
expect '^yes$' $OC $E auth can-i create keycloakusers -n "$NSA"
expect '^yes$' $OC $A auth can-i create keycloakclients -n "$NSA"
expect_apply 'created \(server dry run\)' "$E" "$NSA" <<EOF
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: coverage-check
spec:
  clusterRealmRef:
    name: team-a
  username: coverage-check
EOF
end

begin R1.2 "viewers read only, no secrets" "yes, no, no"
expect '^yes$' $OC $V auth can-i list keycloakusers -n "$NSA"
expect '^no$'  $OC $V auth can-i create keycloakusers -n "$NSA"
expect '^no$'  $OC $V auth can-i get secrets -n "$NSA"
end

hr; say "R2  A tenant cannot reach any other realm"

begin R2.1 "other realm and master refused" 'guard: "must be team-a in this namespace"'
for realm in master team-b; do
expect_apply 'ValidatingAdmissionPolicy.*must be team-a in this namespace' "$E" "$NSA" <<EOF
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: coverage-check
spec:
  clusterRealmRef:
    name: $realm
  username: coverage-check
EOF
done
end

begin R2.2 "unlabelled namespace refused" 'yes, then guard: "is not onboarded"'
expect '^yes$' $OC $C auth can-i create keycloakusers -n "$NSC"
expect_apply 'ValidatingAdmissionPolicy.*not onboarded' "$C" "$NSC" <<EOF
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: coverage-check
spec:
  clusterRealmRef:
    name: team-a
  username: coverage-check
EOF
end

begin R2.3 "realmRef refused" "guard refusal mentioning realmRef"
expect_apply 'ValidatingAdmissionPolicy.*realmRef' "$E" "$NSA" <<EOF
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakUser
metadata:
  name: coverage-check
spec:
  realmRef:
    name: anything
  username: coverage-check
EOF
end

begin R2.4 "indirect refs cannot name a namespace" 'unknown field "spec.clientRef.namespace"'
expect_apply 'unknown field "spec.clientRef.namespace"' "$E" "$NSA" <<EOF
apiVersion: keycloak.hostzero.com/v1beta1
kind: KeycloakRole
metadata:
  name: coverage-check
spec:
  clientRef:
    name: someone-elses-client
    namespace: $NSB
  name: hijack
  definition: {}
EOF
end

begin R2.5 "tenant cannot change the label" "Forbidden, field is immutable, Forbidden"
expect '[Ff]orbidden' $OC $A label namespace "$NSA" "$LABEL=team-b" --overwrite --dry-run=server
if [ "$HAS_PROJECT_API" = 1 ]; then
  expect 'field is immutable|[Ff]orbidden' $OC $A label project "$NSA" "$LABEL=team-b" --overwrite --dry-run=server
  expect 'field is immutable|[Ff]orbidden' $OC $C label project "$NSC" "$LABEL=team-a" --overwrite --dry-run=server
fi
expect '[Ff]orbidden' $OC $A label namespace "$NSA" "$LABEL-" --dry-run=server
end
[ "$HAS_PROJECT_API" = 1 ] || say "        (no project API in this cluster: the project lines were not run)"

review R2.6 "AppProject destinations per team" "own namespaces only, CLUSTER empty" \
  $OC get appproject -n "$ARGONS" -o custom-columns='NAME:.metadata.name,DESTINATIONS:.spec.destinations[*].namespace,CLUSTER:.spec.clusterResourceWhitelist'

crb_list() {
  $OC get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="admin" or .roleRef.name=="edit" or .roleRef.name=="view") | "\(.metadata.name): \(.roleRef.name) -> \([.subjects[]? | "\(.kind)/\(.name)"] | join(", "))"'
}
begin R2.7 "no cluster-wide admin/edit/view groups" "platform service accounts only, no Group/ or User/"
expect_absent 'Group/|User/' crb_list
end
crb_list | sed 's/^/        | /'

hr; say "R3  Admin credentials only where the operator runs; no tenant connections"

begin R3.1 "namespaced KeycloakInstance refused" 'yes, then guard: "managed by the platform team"'
expect '^yes$' $OC $E auth can-i create keycloakinstances -n "$NSA"
expect_apply 'ValidatingAdmissionPolicy.*managed by the platform team' "$E" "$NSA" <<EOF
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
end

begin R3.2 "admin Secret and operator out of reach" "no on all four"
expect '^no$' $OC $A auth can-i get secrets -n "$OPNS"
expect '^no$' $OC $A auth can-i create pods/exec -n "$OPNS"
expect '^no$' $OC $A auth can-i create serviceaccounts/token -n "$OPNS"
expect '^no$' $OC $A auth can-i list secrets
end

begin R3.3 "cluster instances out of reach" "no, no"
expect '^no$' $OC $A auth can-i get clusterkeycloakinstances
expect '^no$' $OC $A auth can-i create clusterkeycloakinstances
end

begin R3.4 "instance secretRef reaches any namespace" "namespace among the keys"
expect '"namespace"' sh -c "$OC get crd clusterkeycloakinstances.keycloak.hostzero.com -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.auth.properties.passwordGrant.properties.secretRef.properties}' | jq keys"
end
review R3.4b "infra Argo CD syncs only platform repositories" "every repository is platform-owned" \
  $OC get applications -n openshift-gitops -o custom-columns='NAME:.metadata.name,REPO:.spec.source.repoURL'

hr; say "R4  Realms are a platform action"

begin R4.1 "namespaced KeycloakRealm refused" 'yes, then guard: "managed by the platform team"'
expect '^yes$' $OC $E auth can-i create keycloakrealms -n "$NSA"
expect_apply 'ValidatingAdmissionPolicy.*managed by the platform team' "$E" "$NSA" <<EOF
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
end

begin R4.2 "cluster realms out of reach" "no on all five"
for v in get list create patch delete; do
  expect '^no$' $OC $A auth can-i "$v" clusterkeycloakrealms
done
end

hr; say "R5  Onboarding without per-tenant code"
if [ -n "$($OC get ns -l "$LABEL" -o name 2>/dev/null | grep -v guard-test)" ]; then
  review R5 "onboarding objects" "every tenant namespace labelled, one realm per tenant" \
    sh -c "$OC get ns -l $LABEL --show-labels | grep -v guard-test; $OC get clusterkeycloakrealm"
else
  skip R5 "onboarding objects" "every tenant namespace labelled, one realm" "no tenant onboarded yet"
fi

hr; say "R6  Day-2 behaviour"
skip R6 "day-2" "needs real objects" "not a dry-run test"

hr; say "R7  The guards exist, fail closed, cover every namespace except the operator's"
begin R7 "guards fail closed, cover all namespaces" "Fail on both, Deny, selector excludes only $OPNS"
expect '^Fail( Fail)*$' sh -c "$OC get validatingadmissionpolicy -o jsonpath='{.items[*].spec.failurePolicy}'"
expect_absent 'Ignore' sh -c "$OC get validatingadmissionpolicy -o jsonpath='{.items[*].spec.failurePolicy}'"
expect '^Deny( Deny)*$' sh -c "$OC get validatingadmissionpolicybinding -o jsonpath='{.items[*].spec.validationActions[0]}'"
expect "$OPNS" sh -c "$OC get validatingadmissionpolicybinding -o jsonpath='{.items[*].spec.matchResources.namespaceSelector.matchExpressions[*].values[*]}'"
end
$OC get validatingadmissionpolicybinding -o custom-columns='NAME:.metadata.name,POLICY:.spec.policyName,ACTIONS:.spec.validationActions,EXCLUDES:.spec.matchResources.namespaceSelector.matchExpressions[*].values' 2>&1 | sed 's/^/        | /'

hr; say "R8  Tenants cannot pass rights beyond their own namespace"
begin R8 "sharing inside namespace only" "created, Forbidden, Forbidden"
expect 'created \(server dry run\)' $OC $A create rolebinding share -n "$NSA" --clusterrole=edit --group=system:authenticated --dry-run=server
expect '[Ff]orbidden' $OC $A create rolebinding share -n "$NSB" --clusterrole=edit --group=system:authenticated --dry-run=server
expect '[Ff]orbidden' $OC $A create rolebinding esc -n "$NSA" --clusterrole=cluster-admin --group=team-a-admin --dry-run=server
end

hr; say "R9  The tenant controller holds nothing cluster-wide"
begin R9 "controller nothing cluster-wide" "no on every line"
expect '^no$' $OC $S auth can-i patch namespaces
expect '^no$' $OC $S auth can-i create namespaces
[ "$HAS_PROJECT_API" = 1 ] && expect '^no$' $OC $S auth can-i patch projects
expect '^no$' $OC $S auth can-i create clusterkeycloakrealms
expect '^no$' $OC $S auth can-i create clusterrolebindings
expect '^no$' $OC $S auth can-i list namespaces
end

hr; say "R10 The operator version and its roles"
review R10.1 "operator version" "record the version" \
  sh -c "$OC get csv -A 2>/dev/null | grep -i hostzero || echo 'no CSV found (not installed through OLM?)'"
review R10.2 "aggregated roles" "one -admin role per Hostzero kind; note RHBK kinds" \
  sh -c "$OC get clusterrole -l rbac.authorization.k8s.io/aggregate-to-admin=true -o name | grep -Ei 'hostzero|keycloak' | sed 's#clusterrole.rbac.authorization.k8s.io/##'"

# --- results -----------------------------------------------------------------------------

hr
say "Results ($TODAY)"
say ""
say "| Test | Expected | Result | Date |"
say "|---|---|---|---|"
for row in "${ROWS[@]}"; do
  IFS='|' read -r id desc expected result <<<"$row"
  say "| $id $desc | $expected | $result | $TODAY |"
done
fails=$(printf '%s\n' "${ROWS[@]}" | grep -c '|FAIL' || true)
say ""
say "FAIL: $fails    (REVIEW rows need a human; SKIP rows did not run)"
exit 0
