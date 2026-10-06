"""R2: a tenant cannot reach any realm other than its own.

The attack tests: tenant-1 tries in different ways to place objects in tenant-2's realm or
in the master realm. Each attempt must be rejected, and Keycloak must show that nothing
landed in the wrong realm.
"""

import time

import pytest

from lab import (PLATFORM, TENANT1, assert_denied, in_realm, keycloak_object,
                 status, wait_ready)

# The message the realm guard gives when an object points at the wrong realm.
WRONG_REALM = "must be tenant-1"


# --- Pointing directly at another realm ---------------------------------------------------

# Every kind that is placed directly in a realm, with the fields it needs besides the realm.
DIRECTLY_PLACED = [
    ("KeycloakUser", {"username": "evil"}),
    ("KeycloakGroup", {"name": "evil", "definition": {"name": "evil"}}),
    ("KeycloakRole", {"name": "evil", "definition": {"name": "evil"}}),
    ("KeycloakClient", {"clientId": "evil"}),
    ("KeycloakClientScope", {"name": "evil", "definition": {"name": "evil"}}),
    ("KeycloakOrganization", {"name": "evil", "definition": {"name": "evil"}}),
    ("KeycloakIdentityProvider", {"alias": "evil", "definition": {"providerId": "oidc"}}),
]


@pytest.mark.parametrize("kind, fields", DIRECTLY_PLACED, ids=[k for k, _ in DIRECTLY_PLACED])
def test_cannot_point_at_another_tenants_realm(kind, fields):
    """tenant-1 creates an object in its own namespace, but points it at realm tenant-2."""
    evil = keycloak_object(kind, "evil", **in_realm("tenant-2"), **fields)
    assert_denied(TENANT1.apply(evil, namespace="tenant-1"), because=WRONG_REALM)


def test_cannot_point_at_master_realm():
    """tenant-1 points a user at the master realm, the one that controls all of Keycloak."""
    evil = keycloak_object("KeycloakUser", "evil", **in_realm("master"), username="evil")
    assert_denied(TENANT1.apply(evil, namespace="tenant-1"), because=WRONG_REALM)


def test_cannot_use_namespaced_realm_reference():
    """realmRef (a realm defined in a namespace) is not allowed for tenants at all.

    Tenants must use the realm the platform created for them (clusterRealmRef).
    """
    evil = keycloak_object("KeycloakUser", "evil", realmRef={"name": "tenant-2"}, username="evil")
    assert_denied(TENANT1.apply(evil, namespace="tenant-1"),
                  because=r"realmRef \(namespaced realm\) is not allowed")


def test_cannot_move_existing_object_to_another_realm(tenant1_content):
    """tenant-1 changes an existing user (alice) to point at realm tenant-2 instead.

    The guard checks changes, not only new objects.
    """
    assert wait_ready("keycloakuser", "alice", "tenant-1")
    move = [{"op": "replace", "path": "/spec/clusterRealmRef/name", "value": "tenant-2"}]
    assert_denied(TENANT1.patch("keycloakuser", "alice", move, namespace="tenant-1"),
                  because=WRONG_REALM)


def test_cannot_swap_to_namespaced_realm_reference(tenant1_content):
    """tenant-1 swaps alice's realm reference for a namespaced one (realmRef)."""
    assert wait_ready("keycloakuser", "alice", "tenant-1")
    swap = [{"op": "remove", "path": "/spec/clusterRealmRef"},
            {"op": "add", "path": "/spec/realmRef", "value": {"name": "x"}}]
    assert_denied(TENANT1.patch("keycloakuser", "alice", swap, namespace="tenant-1"),
                  because="realmRef")


def test_cannot_create_objects_in_another_tenants_namespace():
    """tenant-1 has no rights at all in tenant-2's namespace (RBAC)."""
    evil = keycloak_object("KeycloakUser", "evil", **in_realm("tenant-2"), username="evil")
    assert_denied(TENANT1.apply(evil, namespace="tenant-2"), because="forbidden")


def test_cannot_read_another_tenants_secrets():
    """tenant-2's Secrets hold its passwords and client secrets."""
    assert_denied(TENANT1.kubectl("get", "secrets", "-n", "tenant-2"), because="forbidden")


# --- Deny by default: namespaces that are not onboarded -----------------------------------


def test_unonboarded_namespace_cannot_reference_any_realm(unonboarded_namespace):
    """A namespace without the tenant label cannot place anything in any realm.

    Tested as cluster admin: even someone with every right cannot do it. So if someone
    gets Keycloak rights in a random namespace by mistake, they still reach no realm.
    """
    stray = keycloak_object("KeycloakUser", "stray", **in_realm("tenant-1"), username="stray")
    assert_denied(PLATFORM.apply(stray, namespace=unonboarded_namespace), because="is not onboarded")


def test_unonboarded_namespace_cannot_use_namespaced_realm(unonboarded_namespace):
    stray = keycloak_object("KeycloakUser", "stray", realmRef={"name": "anything"}, username="stray")
    assert_denied(PLATFORM.apply(stray, namespace=unonboarded_namespace),
                  because=r"realmRef \(namespaced realm\)")


def test_guard_applies_to_cluster_admins_too():
    """Even a cluster admin cannot place an object from tenant-1's namespace in tenant-2."""
    stray = keycloak_object("KeycloakUser", "stray", **in_realm("tenant-2"), username="stray")
    assert_denied(PLATFORM.apply(stray, namespace="tenant-1"), because=WRONG_REALM)


# --- Indirect placement: objects that point at another object -----------------------------
#
# Some objects are not placed in a realm directly but through another object: a client role
# through its client, a password through its user, and so on. The guard does not check
# these. They are safe because the operator only looks the parent up in the object's own
# namespace. These tests try to point at objects that exist only in tenant-2's namespace.

INDIRECT_ATTACKS = [
    # A role on tenant-2's client.
    keycloak_object("KeycloakRole", "hijack-role", clientRef={"name": "t2-app", "namespace": "tenant-2"},
                    name="hijacked", definition={}),
    # A service account user for tenant-2's client.
    keycloak_object("KeycloakUser", "hijack-sa", clientRef={"name": "t2-app", "namespace": "tenant-2"}),
    # A subgroup under tenant-2's group.
    keycloak_object("KeycloakGroup", "hijack-group",
                    parentGroupRef={"name": "t2-group", "namespace": "tenant-2"},
                    name="hijacked", definition={}),
    # A new password for tenant-2's user bob.
    keycloak_object("KeycloakUserCredential", "hijack-cred",
                    userRef={"name": "bob", "namespace": "tenant-2"},
                    userSecret={"secretName": "alice-pw", "usernameKey": "username",
                                "passwordKey": "password"}),
    # A token mapper on tenant-2's client, adding a claim to its tokens.
    keycloak_object("KeycloakProtocolMapper", "hijack-mapper",
                    clientRef={"name": "t2-app", "namespace": "tenant-2"}, name="hijacked",
                    definition={"protocol": "openid-connect",
                                "protocolMapper": "oidc-hardcoded-claim-mapper",
                                "config": {"claim.name": "pwned", "claim.value": "1"}}),
    # Realm admin rights for tenant-2's user bob.
    keycloak_object("KeycloakRoleMapping", "hijack-mapping",
                    subject={"userRef": {"name": "bob", "namespace": "tenant-2"}},
                    role={"name": "admin", "clientId": "realm-management"}),
]


@pytest.fixture(scope="module")
def indirect_attacks_applied(tenant1_content, tenant2_content):
    """Sends the attacks with --validate=false, so the API server drops fields it does not
    know (such as namespace on a reference) instead of rejecting them."""
    TENANT1.apply(*INDIRECT_ATTACKS, namespace="tenant-1", validate=False)
    time.sleep(10)  # give the operator time to try


def test_reference_to_another_namespace_is_rejected():
    """References have no namespace field, so naming tenant-2's namespace is rejected."""
    assert_denied(TENANT1.apply(*INDIRECT_ATTACKS, namespace="tenant-1"), because="unknown field")


@pytest.mark.parametrize("attack", INDIRECT_ATTACKS, ids=[a["metadata"]["name"] for a in INDIRECT_ATTACKS])
def test_reference_resolves_in_own_namespace_only(indirect_attacks_applied, attack):
    """With validation off, the namespace field is dropped and the operator looks for the
    target in tenant-1's namespace, where it does not exist. Nothing is applied."""
    kind, name = attack["kind"].lower(), attack["metadata"]["name"]
    stored = PLATFORM.kubectl("get", kind, name, "-n", "tenant-1", "-o", "jsonpath={.spec}")
    assert '"namespace"' not in stored.output, "the namespace field should have been dropped"
    state = status(kind, name, "tenant-1")
    assert state.get("ready") is not True, f"must not be applied, but status is {state}"
    assert "not found" in state.get("message", ""), state


def test_keycloak_tenant2_client_untouched(indirect_attacks_applied, keycloak):
    """In Keycloak, tenant-2's client got no extra role and no extra token mapper."""
    t2_app = keycloak.client("tenant-2", "t2-app")
    roles = keycloak.get(f"tenant-2/clients/{t2_app['id']}/roles")
    mappers = keycloak.get(f"tenant-2/clients/{t2_app['id']}/protocol-mappers/models")
    assert not any(r["name"] == "hijacked" for r in roles)
    assert not any(m["name"] == "hijacked" for m in mappers)


def test_keycloak_tenant2_user_untouched(indirect_attacks_applied, keycloak):
    """In Keycloak, tenant-2's user bob got no password and no admin roles from tenant-1."""
    bob = keycloak.user("tenant-2", "bob")
    assert keycloak.get(f"tenant-2/users/{bob['id']}/credentials") == []
    mappings = keycloak.get(f"tenant-2/users/{bob['id']}/role-mappings")
    assert "realm-management" not in mappings.get("clientMappings", {})


# --- Smuggling through the free-form definition -------------------------------------------
#
# spec.definition is passed to Keycloak more or less as is, so a tenant can put any field
# there. These tests try fields that name another realm.


def test_component_with_other_realms_parent_stays_in_own_realm(tenant2_content, keycloak):
    """A component (here a signing key) whose definition names tenant-2's realm as parent.

    Keycloak stores it in tenant-1's realm anyway: the URL the operator calls decides the
    realm, not the definition. It has no effect on tenant-2.
    """
    tenant2_id = keycloak.realm("tenant-2")["id"]
    smuggled = keycloak_object(
        "KeycloakComponent", "smuggle-parent", **in_realm("tenant-1"), name="smuggled-key",
        definition={"parentId": tenant2_id, "providerId": "rsa-generated",
                    "providerType": "org.keycloak.keys.KeyProvider", "config": {"priority": ["1"]}},
    )
    TENANT1.apply(smuggled, namespace="tenant-1")
    time.sleep(10)
    assert keycloak.get("tenant-2/components?name=smuggled-key") == []


def test_user_with_other_realm_in_definition_stays_in_own_realm(keycloak):
    """A user whose definition says realm: tenant-2. It does not land in tenant-2."""
    smuggled = keycloak_object("KeycloakUser", "smuggle-user", **in_realm("tenant-1"),
                               username="smuggle", definition={"realm": "tenant-2"})
    TENANT1.apply(smuggled, namespace="tenant-1")
    time.sleep(10)
    assert keycloak.user("tenant-2", "smuggle") is None
