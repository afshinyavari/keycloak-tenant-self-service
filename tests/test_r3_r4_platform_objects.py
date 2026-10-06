"""R3 and R4: the Keycloak connection, its admin credentials and the realms belong to the
platform team.

R3: tenants can never get hold of the Keycloak admin credentials, or make a connection of
their own.
R4: tenants cannot create, change or delete realms, only fill their own with content.
"""

from lab import (API, PLATFORM, TENANT1, assert_denied, keycloak_object)

# The message from the platform-kinds guard.
PLATFORM_OWNED = "managed by the platform team"


# --- R3: admin credentials and connections ------------------------------------------------


def test_cannot_read_keycloak_admin_secret():
    """The admin login lives only in the operator's namespace, which tenants cannot read."""
    result = TENANT1.kubectl("get", "secret", "keycloak-ocp-01-admin", "-n", "keycloak-operator")
    assert_denied(result, because="forbidden")


def test_cannot_list_secrets_across_the_cluster():
    assert_denied(TENANT1.kubectl("get", "secrets", "--all-namespaces"), because="forbidden")


def test_cannot_exec_into_operator():
    """Getting a shell in the operator pod would expose its admin login."""
    result = TENANT1.kubectl("exec", "-n", "keycloak-operator", "deploy/keycloak-operator", "--", "true")
    assert_denied(result, because="forbidden")


def test_cannot_create_own_connection_in_namespace():
    """A KeycloakInstance in the tenant's namespace would be a Keycloak connection of its own."""
    connection = keycloak_object("KeycloakInstance", "own-conn",
                                 baseUrl="http://keycloak.keycloak.svc:8080",
                                 auth={"passwordGrant": {"secretRef": {"name": "alice-pw"}}})
    assert_denied(TENANT1.apply(connection, namespace="tenant-1"), because="forbidden")


def test_cannot_create_cluster_connection_reusing_admin_secret():
    """A cluster-wide connection that points at the platform's admin Secret."""
    connection = {
        "apiVersion": API, "kind": "ClusterKeycloakInstance", "metadata": {"name": "own-conn"},
        "spec": {"baseUrl": "http://keycloak.keycloak.svc:8080",
                 "auth": {"passwordGrant": {"secretRef": {"name": "keycloak-ocp-01-admin",
                                                          "namespace": "keycloak-operator"}}}},
    }
    assert_denied(TENANT1.apply(connection), because="forbidden")


# --- R4: realms -----------------------------------------------------------------------------


def test_cannot_create_a_realm():
    realm = {"apiVersion": API, "kind": "ClusterKeycloakRealm", "metadata": {"name": "tenant-1-extra"},
             "spec": {"clusterInstanceRef": {"name": "ocp-01"}, "realmName": "tenant-1-extra",
                      "definition": {"enabled": True}}}
    assert_denied(TENANT1.apply(realm), because="forbidden")


def test_cannot_change_own_realm_settings():
    """Realm settings (for example whether users may sign themselves up) are the platform's."""
    change = [{"op": "add", "path": "/spec/definition/registrationAllowed", "value": True}]
    assert_denied(TENANT1.patch("clusterkeycloakrealm", "tenant-1", change), because="forbidden")


def test_cannot_delete_own_realm():
    assert_denied(TENANT1.delete("clusterkeycloakrealm", "tenant-1"), because="forbidden")


def test_cannot_create_namespaced_realm():
    realm = keycloak_object("KeycloakRealm", "own-realm", clusterInstanceRef={"name": "ocp-01"},
                            realmName="own-realm", definition={})
    assert_denied(TENANT1.apply(realm, namespace="tenant-1"), because="forbidden")


def test_cannot_move_namespace_to_another_realm():
    """The namespace label decides which realm the namespace may use. Tenants cannot change it."""
    result = TENANT1.kubectl("label", "namespace", "tenant-1",
                             "keycloak.lab/tenant-realm=tenant-2", "--overwrite")
    assert_denied(result, because="forbidden")


def test_cannot_create_namespaces():
    assert_denied(TENANT1.kubectl("create", "namespace", "sneaky"), because="forbidden")


def test_cannot_delete_own_namespace():
    assert_denied(TENANT1.kubectl("delete", "namespace", "tenant-1", "--wait=false"), because="forbidden")


# --- Platform-kinds guard: realm takeover -------------------------------------------------
#
# A namespaced KeycloakRealm can point at the platform's Keycloak connection and name any
# realm. The operator would then create that realm, or take over an existing one, with the
# platform's admin login. Tenants lack the rights to try (see above), but other identities
# with broad rights in a tenant namespace, such as a GitOps controller, have them. These
# tests use the cluster admin to stand in for such an identity.


def test_realm_takeover_of_another_tenant_is_blocked(keycloak):
    takeover = keycloak_object("KeycloakRealm", "takeover", clusterInstanceRef={"name": "ocp-01"},
                               realmName="tenant-2", definition={"displayName": "PWNED"})
    assert_denied(PLATFORM.apply(takeover, namespace="tenant-1"), because=PLATFORM_OWNED)
    assert keycloak.realm("tenant-2")["displayName"] == "Tenant 2"


def test_master_realm_takeover_is_blocked(unonboarded_namespace):
    takeover = keycloak_object("KeycloakRealm", "takeover-master", clusterInstanceRef={"name": "ocp-01"},
                               realmName="master", definition={"enabled": True})
    assert_denied(PLATFORM.apply(takeover, namespace=unonboarded_namespace), because=PLATFORM_OWNED)


def test_own_connection_is_blocked_even_for_admins():
    connection = keycloak_object("KeycloakInstance", "own-conn",
                                 baseUrl="http://keycloak.keycloak.svc:8080",
                                 auth={"passwordGrant": {"secretRef": {"name": "x"}}})
    assert_denied(PLATFORM.apply(connection, namespace="tenant-1"), because=PLATFORM_OWNED)
