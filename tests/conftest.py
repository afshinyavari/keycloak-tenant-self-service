"""Shared setup for all tests (pytest picks this file up automatically).

A "fixture" is something a test needs before it can run, for example a connection to
Keycloak or a set of objects that must already exist. A test asks for a fixture by naming
it as a parameter.
"""

import socket
import subprocess
import time

import pytest
import requests

from lab import PLATFORM, TENANT1, TENANT2, Keycloak, in_realm, keycloak_object, secret, wait_ready

KEYCLOAK_KINDS = ",".join([
    "keycloakusercredentials", "keycloakrolemappings", "keycloakprotocolmappers",
    "keycloakroles", "keycloakusers", "keycloakgroups", "keycloakclients", "keycloakcomponents",
])


def clean_up():
    """Remove everything earlier test runs created, so every run starts from the same state."""
    for namespace in ["tenant-1", "tenant-2"]:
        PLATFORM.kubectl("delete", KEYCLOAK_KINDS, "-n", namespace, "-l", "lab-test=true",
                         "--ignore-not-found", "--wait=true", "--timeout=60s")
        PLATFORM.kubectl("delete", "secret", "-n", namespace, "-l", "lab-test=true", "--ignore-not-found")
        PLATFORM.kubectl("delete", "rolebinding", "oops-admin", "-n", namespace, "--ignore-not-found")
    for namespace in ["lab-unonboarded", "lab-offboard"]:
        PLATFORM.kubectl("delete", "namespace", namespace, "--ignore-not-found", "--wait=true")


@pytest.fixture(scope="session", autouse=True)
def clean_lab():
    """Runs once before all tests and once after them."""
    clean_up()
    yield
    clean_up()


@pytest.fixture(scope="session")
def keycloak():
    """Access to Keycloak's admin API, through a port-forward to the Keycloak service."""
    with socket.socket() as s:
        s.bind(("", 0))
        port = s.getsockname()[1]
    forward = subprocess.Popen(
        ["kubectl", "-n", "keycloak", "port-forward", "svc/keycloak", f"{port}:8080"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    base_url = f"http://localhost:{port}"
    for _ in range(30):
        try:
            requests.get(f"{base_url}/realms/master", timeout=1)
            break
        except requests.ConnectionError:
            time.sleep(1)
    yield Keycloak(base_url)
    forward.terminate()


@pytest.fixture(scope="session")
def unonboarded_namespace():
    """A namespace without the tenant label: it has not been onboarded to any realm."""
    PLATFORM.kubectl("create", "namespace", "lab-unonboarded")
    return "lab-unonboarded"


@pytest.fixture(scope="session")
def tenant1_content():
    """Realm content that tenant-1 creates in its own realm, the normal everyday use.

    alice:        a user, with a password from a Secret
    app1:         a confidential client; the operator generates its secret
    app1-reader:  a role on that client
    editor:       a realm role, given to alice
    devs:         a group, with the nested group devs-backend
    app1-dept:    a protocol mapper on app1
    """
    result = TENANT1.apply(
        secret("alice-pw", username="alice", password="S3cret-alice!"),
        keycloak_object("KeycloakUser", "alice", **in_realm("tenant-1"), username="alice",
                        definition={"enabled": True, "email": "alice@tenant1.example"}),
        keycloak_object("KeycloakUserCredential", "alice-pw", userRef={"name": "alice"},
                        userSecret={"secretName": "alice-pw", "usernameKey": "username",
                                    "passwordKey": "password"}),
        keycloak_object("KeycloakClient", "app1", **in_realm("tenant-1"), clientId="app1",
                        definition={"enabled": True, "publicClient": False,
                                    "serviceAccountsEnabled": True},
                        clientSecretRef={"name": "app1-credentials", "create": True}),
        keycloak_object("KeycloakRole", "app1-reader", clientRef={"name": "app1"},
                        name="reader", definition={"description": "read access"}),
        keycloak_object("KeycloakRole", "editor", **in_realm("tenant-1"), name="editor",
                        definition={"description": "editor"}),
        keycloak_object("KeycloakGroup", "devs", **in_realm("tenant-1"), name="devs", definition={}),
        keycloak_object("KeycloakGroup", "devs-backend", parentGroupRef={"name": "devs"},
                        name="backend", definition={}),
        keycloak_object("KeycloakRoleMapping", "alice-editor",
                        subject={"userRef": {"name": "alice"}}, roleRef={"name": "editor"}),
        keycloak_object("KeycloakProtocolMapper", "app1-dept", clientRef={"name": "app1"},
                        name="department",
                        definition={"protocol": "openid-connect",
                                    "protocolMapper": "oidc-usermodel-attribute-mapper",
                                    "config": {"user.attribute": "department", "claim.name": "dept",
                                               "access.token.claim": "true"}}),
        namespace="tenant-1",
    )
    return result


@pytest.fixture(scope="session")
def tenant2_content():
    """Objects tenant-2 owns in its realm. tenant-1 uses them as targets in the attack tests."""
    result = TENANT2.apply(
        keycloak_object("KeycloakClient", "t2-app", **in_realm("tenant-2"), clientId="t2-app",
                        definition={"enabled": True}),
        keycloak_object("KeycloakUser", "bob", **in_realm("tenant-2"), username="bob"),
        keycloak_object("KeycloakGroup", "t2-group", **in_realm("tenant-2"), name="t2-group",
                        definition={}),
        namespace="tenant-2",
    )
    assert result.ok, result.output
    assert wait_ready("keycloakclient", "t2-app", "tenant-2")
    assert wait_ready("keycloakuser", "bob", "tenant-2")
    return result
