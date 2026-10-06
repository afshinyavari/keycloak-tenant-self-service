"""R1: tenants manage everything inside their realm themselves, with Kubernetes objects.

These are the "happy path" tests: a tenant's developer creates users, clients, roles and
groups in their own namespace, and the operator puts them in the tenant's realm in Keycloak.
"""

import base64
import json

import pytest

from lab import TENANT1, Identity, assert_allowed, assert_denied, status, wait_ready


def test_tenant_can_create_realm_content(tenant1_content):
    """tenant-1's developer may create all the usual realm content in its namespace."""
    assert_allowed(tenant1_content)


@pytest.mark.parametrize("kind, name", [
    ("keycloakuser", "alice"),
    ("keycloakusercredential", "alice-pw"),
    ("keycloakclient", "app1"),
    ("keycloakrole", "app1-reader"),
    ("keycloakrole", "editor"),
    ("keycloakgroup", "devs"),
    ("keycloakgroup", "devs-backend"),
    ("keycloakrolemapping", "alice-editor"),
    ("keycloakprotocolmapper", "app1-dept"),
])
def test_operator_applies_content_to_keycloak(tenant1_content, kind, name):
    """The operator picks up each object and reports it as applied (Ready)."""
    assert wait_ready(kind, name, "tenant-1"), status(kind, name, "tenant-1").get("message")


def test_user_ends_up_in_the_tenants_realm(tenant1_content, keycloak):
    """alice exists in Keycloak, in realm tenant-1."""
    assert wait_ready("keycloakuser", "alice", "tenant-1")
    assert keycloak.user("tenant-1", "alice") is not None


def test_client_ends_up_in_the_tenants_realm(tenant1_content, keycloak):
    """The client app1 exists in Keycloak, in realm tenant-1."""
    assert wait_ready("keycloakclient", "app1", "tenant-1")
    assert keycloak.client("tenant-1", "app1") is not None


def test_password_from_secret_is_set(tenant1_content, keycloak):
    """The password the tenant put in a Secret was set on alice in Keycloak."""
    assert wait_ready("keycloakusercredential", "alice-pw", "tenant-1")
    alice = keycloak.user("tenant-1", "alice")
    credentials = keycloak.get(f"tenant-1/users/{alice['id']}/credentials")
    assert any(c["type"] == "password" for c in credentials)


def test_tenant_can_read_its_generated_client_secret(tenant1_content):
    """The operator writes app1's client secret to a Secret the tenant can read and use."""
    assert wait_ready("keycloakclient", "app1", "tenant-1")
    result = TENANT1.kubectl("get", "secret", "app1-credentials", "-n", "tenant-1", "-o", "json")
    assert_allowed(result)
    client_secret = base64.b64decode(json.loads(result.output)["data"]["client-secret"]).decode()
    assert len(client_secret) > 10


def test_tenant2_manages_its_own_realm(tenant2_content, keycloak):
    """tenant-2 works the same way, in its own realm."""
    assert keycloak.client("tenant-2", "t2-app") is not None
    assert keycloak.user("tenant-2", "bob") is not None


def test_rights_come_from_the_tenant_group():
    """The same person, without the tenant-1 editor group, has no access.

    Shows that access is given to the OIDC group, so it is managed in the identity
    provider: removing someone from the group removes their access.
    """
    without_group = Identity("tenant-1 developer, not in the group",
                             ["--as=oidc-user:tenant1-dev@example.com"])
    assert_denied(without_group.kubectl("get", "keycloakusers", "-n", "tenant-1"), because="forbidden")


def test_other_tenants_group_has_no_access():
    """A member of tenant-2's editor group has no access in tenant-1's namespace."""
    tenant2_member = Identity("member of tenant-2's group",
                              ["--as=oidc-user:someone@example.com",
                               "--as-group=oidc-groups:tenant-2-editors"])
    assert_denied(tenant2_member.kubectl("get", "keycloakusers", "-n", "tenant-1"), because="forbidden")
