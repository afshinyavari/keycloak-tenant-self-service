"""R8: tenants cannot change who has access to their namespace.

Whoever can create RoleBindings in a tenant namespace can hand the tenant's Keycloak rights
to anyone, for example every logged-in user. Tenants get the built-in "edit" role, which
cannot touch RBAC. As a backstop, the admission policy tenant-rbac-guard rejects RBAC
changes in tenant namespaces from anyone but the platform, so it holds even if someone
gives a tenant the "admin" role by mistake.
"""

import pytest

from lab import PLATFORM, TENANT1, assert_allowed, assert_denied, in_realm, keycloak_object

# The message from tenant-rbac-guard.
PLATFORM_MANAGED = "managed by the platform team"

# Gives every logged-in user in the cluster the tenant's Keycloak rights.
SHARE_WITH_EVERYONE = ["create", "rolebinding", "share", "-n", "tenant-1",
                       "--role=keycloak-realm-editor", "--group=system:authenticated"]


# --- Normal case: the tenant has "edit" -----------------------------------------------------


def test_tenant_cannot_create_rolebindings():
    assert_denied(TENANT1.kubectl(*SHARE_WITH_EVERYONE), because="forbidden")


def test_tenant_cannot_delete_its_rolebinding():
    result = TENANT1.kubectl("delete", "rolebinding", "keycloak-realm-editors", "-n", "tenant-1")
    assert_denied(result, because="forbidden")


def test_tenant_cannot_get_a_token_for_the_operator():
    """A token for the operator's service account would carry its Keycloak admin rights."""
    result = TENANT1.kubectl("create", "token", "keycloak-operator", "-n", "keycloak-operator")
    assert_denied(result, because="forbidden|not found")


# --- Mistake case: someone has given the tenant "admin" -------------------------------------


@pytest.fixture
def tenant_given_admin_by_mistake():
    """Binds the built-in "admin" role to tenant-1's group, then removes it again."""
    result = PLATFORM.kubectl("create", "rolebinding", "oops-admin", "-n", "tenant-1",
                              "--clusterrole=admin", "--group=oidc-groups:tenant-1-editors")
    assert_allowed(result)  # also shows that the platform itself can still change RBAC
    yield
    PLATFORM.kubectl("delete", "rolebinding", "oops-admin", "-n", "tenant-1")


def test_admin_tenant_cannot_share_access(tenant_given_admin_by_mistake):
    assert_denied(TENANT1.kubectl(*SHARE_WITH_EVERYONE), because=PLATFORM_MANAGED)


def test_admin_tenant_cannot_create_roles(tenant_given_admin_by_mistake):
    result = TENANT1.kubectl("create", "role", "extra", "-n", "tenant-1", "--verb=get", "--resource=pods")
    assert_denied(result, because=PLATFORM_MANAGED)


def test_admin_tenant_cannot_add_people_to_its_binding(tenant_given_admin_by_mistake):
    everyone = {"kind": "Group", "name": "system:authenticated", "apiGroup": "rbac.authorization.k8s.io"}
    add = [{"op": "add", "path": "/subjects/-", "value": everyone}]
    assert_denied(TENANT1.patch("rolebinding", "keycloak-realm-editors", add, namespace="tenant-1"),
                  because=PLATFORM_MANAGED)


def test_admin_tenant_cannot_widen_its_role(tenant_given_admin_by_mistake):
    extra_rule = {"apiGroups": [""], "resources": ["pods"], "verbs": ["get"]}
    add = [{"op": "add", "path": "/rules/-", "value": extra_rule}]
    assert_denied(TENANT1.patch("role", "keycloak-realm-editor", add, namespace="tenant-1"),
                  because=PLATFORM_MANAGED)


def test_admin_tenant_cannot_delete_its_binding(tenant_given_admin_by_mistake):
    result = TENANT1.kubectl("delete", "rolebinding", "keycloak-realm-editors", "-n", "tenant-1")
    assert_denied(result, because=PLATFORM_MANAGED)


def test_admin_tenant_cannot_remove_the_mistake_itself(tenant_given_admin_by_mistake):
    """Not even the admin binding can be deleted by the tenant; the platform cleans it up."""
    result = TENANT1.kubectl("delete", "rolebinding", "oops-admin", "-n", "tenant-1")
    assert_denied(result, because=PLATFORM_MANAGED)


def test_admin_tenant_still_cannot_reach_another_realm(tenant_given_admin_by_mistake):
    """The realm guard does not depend on RBAC, so "admin" does not open other realms."""
    evil = keycloak_object("KeycloakUser", "evil", **in_realm("tenant-2"), username="evil")
    assert_denied(TENANT1.apply(evil, namespace="tenant-1"), because="must be tenant-1")


def test_admin_tenant_still_cannot_move_its_namespace(tenant_given_admin_by_mistake):
    """"admin" in a namespace does not include changing the namespace's own labels."""
    result = TENANT1.kubectl("label", "namespace", "tenant-1",
                             "keycloak.lab/tenant-realm=tenant-2", "--overwrite")
    assert_denied(result, because="forbidden")
