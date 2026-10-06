"""Helpers for the tests: who sends a request, what to send, and how to check the answer.

The tests talk to the cluster through kubectl, the same way a person would. Tenants are
simulated with impersonation (kubectl --as / --as-group): the request goes through exactly
the same RBAC and admission checks as a real logged-in user.
"""

import json
import re
import subprocess
import time
from dataclasses import dataclass, field

import requests

API = "keycloak.hostzero.com/v1beta1"

# Every object a test creates carries this label, so it can be cleaned up afterwards.
TEST_LABEL = {"lab-test": "true"}


# --- The answer from the cluster ----------------------------------------------------------


@dataclass
class Result:
    """What kubectl answered: whether the request succeeded, and what it printed."""

    ok: bool
    output: str


def assert_allowed(result: Result):
    """The request must have succeeded."""
    assert result.ok, f"expected the request to be allowed, but it was denied:\n{result.output}"


def assert_denied(result: Result, because: str):
    """The request must have been rejected, and for the expected reason.

    `because` is a piece of the error message (a regular expression). Checking the reason
    matters: a request that fails because of a typo in the test would otherwise look like
    a successful denial.
    """
    assert not result.ok, f"expected the request to be denied, but it was allowed:\n{result.output}"
    assert re.search(because, result.output), (
        f"denied, but for the wrong reason. Expected '{because}', got:\n{result.output}"
    )


# --- Who sends the request ----------------------------------------------------------------


@dataclass
class Identity:
    """Someone who talks to the Kubernetes API, for example a tenant's developer."""

    description: str
    kubectl_args: list = field(default_factory=list)

    def kubectl(self, *args, stdin: str = None) -> Result:
        proc = subprocess.run(
            ["kubectl", *self.kubectl_args, *args],
            input=stdin, capture_output=True, text=True,
        )
        return Result(proc.returncode == 0, proc.stdout + proc.stderr)

    def apply(self, *manifests: dict, namespace: str = None, validate: bool = True) -> Result:
        """Create or update objects, like `kubectl apply -f`."""
        args = ["apply", "-f", "-"]
        if namespace:
            args += ["-n", namespace]
        if not validate:
            args.append("--validate=false")
        document = {"apiVersion": "v1", "kind": "List", "items": list(manifests)}
        return self.kubectl(*args, stdin=json.dumps(document))

    def patch(self, kind: str, name: str, patch: list, namespace: str = None) -> Result:
        """Change part of an existing object (a JSON patch)."""
        args = ["patch", kind, name, "--type=json", "-p", json.dumps(patch)]
        if namespace:
            args += ["-n", namespace]
        return self.kubectl(*args)

    def delete(self, kind: str, name: str, namespace: str = None) -> Result:
        args = ["delete", kind, name, "--wait=true", "--timeout=60s"]
        if namespace:
            args += ["-n", namespace]
        return self.kubectl(*args)


# The platform team: kind's admin user, a cluster admin.
PLATFORM = Identity("cluster admin")

# Tenant developers. Their rights come from the OIDC group bound in their namespace.
TENANT1 = Identity(
    "developer in tenant-1",
    ["--as=oidc-user:tenant1-dev@example.com", "--as-group=oidc-groups:tenant-1-editors"],
)
TENANT2 = Identity(
    "developer in tenant-2",
    ["--as=oidc-user:tenant2-dev@example.com", "--as-group=oidc-groups:tenant-2-editors"],
)


# --- What to send: manifests --------------------------------------------------------------


def keycloak_object(kind: str, name: str, /, **spec) -> dict:
    """A Keycloak object for the operator, for example a KeycloakUser.

    `name` is the Kubernetes object name; everything after it goes into spec (which may
    have its own `name` field, the name in Keycloak).
    """
    return {
        "apiVersion": API,
        "kind": kind,
        "metadata": {"name": name, "labels": TEST_LABEL},
        "spec": spec,
    }


def in_realm(realm: str) -> dict:
    """Spec fields that place an object in a platform-owned (cluster-scoped) realm."""
    return {"clusterRealmRef": {"name": realm}}


def secret(name: str, **data) -> dict:
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "labels": TEST_LABEL},
        "stringData": data,
    }


# --- Waiting for the operator -------------------------------------------------------------


def status(kind: str, name: str, namespace: str) -> dict:
    """The status the operator wrote on an object, or {} if the object does not exist."""
    result = PLATFORM.kubectl("get", kind, name, "-n", namespace, "-o", "json")
    return json.loads(result.output).get("status", {}) if result.ok else {}


def wait_ready(kind: str, name: str, namespace: str, timeout: int = 90) -> bool:
    """Wait until the operator reports the object as applied to Keycloak."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if status(kind, name, namespace).get("ready") is True:
            return True
        time.sleep(2)
    return False


# --- Looking inside Keycloak --------------------------------------------------------------


class Keycloak:
    """Reads Keycloak's admin API, to see where objects really ended up.

    A denied request only proves the Kubernetes side. Looking in Keycloak shows what the
    operator actually did.
    """

    def __init__(self, base_url: str):
        self.base_url = base_url

    def _token(self) -> str:
        response = requests.post(
            f"{self.base_url}/realms/master/protocol/openid-connect/token",
            data={"grant_type": "password", "client_id": "admin-cli",
                  "username": "admin", "password": "admin"},
        )
        response.raise_for_status()
        return response.json()["access_token"]

    def get(self, path: str):
        """GET /admin/realms/<path>. Returns None when Keycloak answers 404."""
        response = requests.get(
            f"{self.base_url}/admin/realms/{path}",
            headers={"Authorization": f"Bearer {self._token()}"},
        )
        if response.status_code == 404:
            return None
        response.raise_for_status()
        return response.json()

    def realm(self, realm: str) -> dict:
        return self.get(realm)

    def user(self, realm: str, username: str):
        users = self.get(f"{realm}/users?username={username}&exact=true") or []
        return users[0] if users else None

    def client(self, realm: str, client_id: str):
        clients = self.get(f"{realm}/clients?clientId={client_id}") or []
        return clients[0] if clients else None
