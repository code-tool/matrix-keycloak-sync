# matrix-keycloak-sync
 
A script that synchronizes users from a Keycloak group with user accounts in a Matrix chat (Synapse).
 
---
 
## Overview
 
The script fetches the list of users from a specific Keycloak group and compares them against the user state (enabled/disabled) in the Matrix/Synapse database. User activation and deactivation in Matrix is controlled by Keycloak group membership.

---
 
## User Sync Logic
 
| User in Keycloak group | User in Synapse DB | Action |
|---|---|---|
| ✅ Yes | ✅ Yes (active) | No action needed |
| ✅ Yes | ✅ Yes (disabled) | **Activate** via `mas-cli` |
| ✅ Yes | ❌ No | **Skip** — will be created on first login |
| ❌ No | ✅ Yes (active) | **Disable** via `mas-cli` |
| ❌ No | ✅ Yes (disabled) | No action needed |
 
> **Note:** If a user is present in the Keycloak group but does not yet exist in the Synapse database, they are skipped during this sync run. The user account will be automatically created in Synapse upon their first login via Keycloak SSO.

---
 
## Components
 
### Keycloak
- Source of truth for user access.
- Users added to a designated group are considered **active** in Matrix.
- Users removed from the group will be **disabled** in Matrix on the next sync run.
 
### Synapse API
- Used **read-only** to fetch the current list of users and their `deactivated` status.
- Requires an admin token (see [Authentication](#authentication) below).
 
### mas-cli (Matrix Authentication Service CLI)
- Used to **activate and deactivate** users.
- Requires a `mas-cli.yaml` config file.
- Communicates **directly with the database** — bypasses Synapse API for write operations.
 
> **Why mas-cli instead of Synapse API for writes?**  
> Disabling a user directly in the Synapse database (without going through MAS) is insufficient — MAS will still allow the user to log in even if the `is_disabled = true` flag is set in the Synapse DB. All deactivation must go through `mas-cli` to be effective.
 
---
 
## Authentication
 
### Synapse Admin Token
 
Generate an admin-scoped token via `mas-cli`. It is recommended to create a **dedicated non-admin Matrix user** for management purposes and grant it admin privileges via token only:
 
```bash
mas-cli manage issue-compatibility-token \
  --yes-i-want-to-grant-synapse-admin-privileges \
  <your_matrix_username_for_managing_users>
```
 
---
 
## Configuration
 
### `mas-cli.yaml`
 
Required for `mas-cli` to connect to the database. Example path: `/etc/mas-cli/mas-cli.yaml`.
 
### Environment variables / config for the script
 
| Variable | Description |
|---|---|
| `KC_URL` | Base URL of the Keycloak instance |
| `KC_REALM` | Keycloak realm name |
| `KC_GROUP_NAME` | Name or ID of the group to sync |
| `KC_CLIENT_ID` | Client ID |
| `KC_ADMIN_USER` | User in keycloak in master realm (with restriction permission in specific realm for getting user list)|
| `KC_ADMIN_PASS` | User pass in keycloak in master realm |
| `MATRIX_URL` | Base URL of the Synapse homeserver |
| `MATRIX_ADMIN_TOKEN` | Admin token for Synapse API |
| `MATRIX_SERVER_NAME` | Matrix server name |
 
---
 
## Alternative: MAS Admin API
 
It is also possible to manage users via the [MAS Admin API](https://matrix-org.github.io/matrix-authentication-service/topics/admin-api.html#enabling-the-api) instead of `mas-cli`. However, this approach has additional overhead:
 
- The API must be explicitly enabled in MAS configuration.
- A separate API token must be generated (not the one generated via the MAS CLI).
- The API endpoint is **exposed publicly by default** and requires additional hardening.
 
For these reasons, using `mas-cli` directly is the recommended approach for this script.