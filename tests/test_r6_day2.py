"""R6: deleting and changing objects does the expected thing, also when offboarding.

Each test creates and deletes its own objects.
"""

from lab import (PLATFORM, TENANT1, assert_allowed, assert_denied, in_realm, keycloak_object,
                 wait_ready)


def test_deleting_an_object_removes_it_from_keycloak(keycloak):
    """When the Kubernetes object goes away, the operator removes the user from Keycloak."""
    user = keycloak_object("KeycloakUser", "dan", **in_realm("tenant-1"), username="dan")
    assert_allowed(TENANT1.apply(user, namespace="tenant-1"))
    assert wait_ready("keycloakuser", "dan", "tenant-1")
    assert keycloak.user("tenant-1", "dan") is not None

    assert_allowed(TENANT1.delete("keycloakuser", "dan", namespace="tenant-1"))
    assert keycloak.user("tenant-1", "dan") is None


def test_preserve_annotation_keeps_object_in_keycloak(keycloak):
    """With the preserve annotation, the user stays in Keycloak after its object is deleted."""
    user = keycloak_object("KeycloakUser", "carol", **in_realm("tenant-1"), username="carol")
    user["metadata"]["annotations"] = {"keycloak.hostzero.com/preserve-resource": "true"}
    assert_allowed(TENANT1.apply(user, namespace="tenant-1"))
    assert wait_ready("keycloakuser", "carol", "tenant-1")

    assert_allowed(TENANT1.delete("keycloakuser", "carol", namespace="tenant-1"))
    assert keycloak.user("tenant-1", "carol") is not None


def test_offboarding_a_namespace_with_objects_left(keycloak):
    """The platform removes a namespace's tenant label while Keycloak objects still exist.

    Afterwards:
    - the objects can no longer be changed (the namespace is no longer onboarded),
    - but they can still be deleted, and are removed from Keycloak. Deleting needs the
      operator to remove its finalizer, which is an update. The realm guard lets updates
      that do not change spec through for exactly this reason; otherwise the objects
      would be stuck forever.
    """
    PLATFORM.kubectl("create", "namespace", "lab-offboard")
    PLATFORM.kubectl("label", "namespace", "lab-offboard", "keycloak.lab/tenant-realm=tenant-2")
    user = keycloak_object("KeycloakUser", "dave", **in_realm("tenant-2"), username="dave")
    assert_allowed(PLATFORM.apply(user, namespace="lab-offboard"))
    assert wait_ready("keycloakuser", "dave", "lab-offboard", timeout=60)

    PLATFORM.kubectl("label", "namespace", "lab-offboard", "keycloak.lab/tenant-realm-")

    change = [{"op": "add", "path": "/spec/definition", "value": {"firstName": "D"}}]
    assert_denied(PLATFORM.patch("keycloakuser", "dave", change, namespace="lab-offboard"),
                  because="is not onboarded")

    assert_allowed(PLATFORM.delete("keycloakuser", "dave", namespace="lab-offboard"))
    assert keycloak.user("tenant-2", "dave") is None
