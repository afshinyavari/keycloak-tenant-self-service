{{/*
Who a tenant's RoleBindings are for: the OIDC groups in editorGroups, then any
individual users in editorUsers.
*/}}
{{- define "keycloak.editorSubjects" -}}
{{- range .editorGroups }}
- kind: Group
  name: {{ . | quote }}
  apiGroup: rbac.authorization.k8s.io
{{- end }}
{{- range .editorUsers }}
- kind: User
  name: {{ . | quote }}
  apiGroup: rbac.authorization.k8s.io
{{- end }}
{{- end }}

{{/*
Rules of the keycloak-realm-editor Role. Defined once here and rendered into
every tenant namespace, so all tenants get exactly the same rights. When a new
operator version adds a Keycloak object kind for realm content, add it here.
*/}}
{{- define "keycloak.realmEditorRules" -}}
# Everything that lives inside a realm. Deliberately NOT keycloakinstances,
# keycloakrealms or their cluster-scoped versions: Keycloak connections and
# realms belong to the platform team.
- apiGroups: ["keycloak.hostzero.com"]
  resources:
    - keycloakusers
    - keycloakusercredentials
    - keycloakgroups
    - keycloakroles
    - keycloakrolemappings
    - keycloakclients
    - keycloakclientscopes
    - keycloakprotocolmappers
    - keycloakidentityproviders
    - keycloakidentityprovidermappers
    - keycloakcomponents
    - keycloakauthenticationflows
    - keycloakrequiredactions
    - keycloakorganizations
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Secrets the Keycloak objects read and write: initial passwords, and the client
# secrets the operator generates for confidential clients.
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Read access to the tenant's own namespace, so tools such as oc and Argo CD can
# show it. Read only: the namespace label decides the realm and must not be
# changeable by the tenant.
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get"]
- apiGroups: ["project.openshift.io"]
  resources: ["projects"]
  verbs: ["get"]
{{- end }}
