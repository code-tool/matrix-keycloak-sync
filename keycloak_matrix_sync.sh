#!/bin/bash


DRY_RUN=false
source ./keycloak_matrix_sync.conf
export MAS_CONFIG=./mas-config.yaml

# Output colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Output formats
log()     { echo -e "[$(date '+%H:%M:%S')] $*"; }
info()    { log "${BLUE}[INFO]${NC}  $*"; }
ok()      { log "${GREEN}[OK]${NC}    $*"; }
warn()    { log "${YELLOW}[WARN]${NC}  $*"; }
error()   { log "${RED}[ERROR]${NC} $*"; }

info "=== Keycloak => Matrix Sync ==="
$DRY_RUN && warn "DRY RUN mode -- changes on the Matrix side NOT will be applied"

# =============================================================================
# 1. Retrieving a Keycloak token
# =============================================================================
get_keycloak_token() {

    info "Retrieving a Keycloak token..."

    KC_TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
                    -d "client_id=${KC_CLIENT_ID}" \
                    -d "username=${KC_ADMIN_USER}" \
                    -d "password=${KC_ADMIN_PASS}" \
                    -d "grant_type=password" | jq -r '.access_token')

    if [[ -z "${KC_TOKEN}" || "${KC_TOKEN}" == "null" ]]; then
      error "Unable to get KeyCloak token"
      exit 1
    fi

    ok "KeyCloak token received"
}

# =============================================================================
# 2. Find ID group in Keycloak by group name
# =============================================================================
get_group_id() {
    info "Looking for the '${KC_GROUP_NAME}' group in Keycloak......"

    KC_GROUP_ID=$(curl -sf "${KC_URL}/admin/realms/${KC_REALM}/groups?search=${KC_GROUP_NAME}" \
                   -H "Authorization: Bearer ${KC_TOKEN}" \
                   | jq -r --arg name "$KC_GROUP_NAME" '.[] | select(.name == $name) | .id' | head -1)

    if [[ -z "${KC_GROUP_ID}" ]]; then
      error "Group ${KC_GROUP_NAME} not found in KeyCloak"
      exit 1
    fi

    ok "Group found: ID=${KC_GROUP_ID}"
}

# =============================================================================
# 3. Getting a list of group members from Keycloak
# =============================================================================
get_keycloak_group_users() {
    info "Retrieving group members from Keycloak..."

# Paginate Keycloak  max 100 per request
    KC_GROUP_MEMBERS=()
    FIRST=0
    MAX=100
    while true; do
      BATCH=$(curl -sf \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KC_URL}/admin/realms/${KC_REALM}/groups/${KC_GROUP_ID}/members?first=${FIRST}&max=${MAX}" \
        | jq -r '.[].username')
      [[ -z "$BATCH" ]] && break
      while IFS= read -r u; do KC_GROUP_MEMBERS+=("$u"); done <<< "$BATCH"
      COUNT=$(echo "$BATCH" | wc -l)
      (( COUNT < MAX )) && break
      FIRST=$(( FIRST + MAX ))
    done

    ok "Number of users in the KeyCloak group: ${#KC_GROUP_MEMBERS[@]}"
    for u in "${KC_GROUP_MEMBERS[@]}"; do info "  KC member: $u"; done
}

# # ========================================================================================
# # 4. Retrieve all local Matrix users (Admin API) (check users from Synapse, not from MAS)
# # ========================================================================================
get_matrix_users() {
    info "Getting Matrix users..."

    # Synapse Admin API: /_synapse/admin/v2/users
    MATRIX_USERS=()
    FROM=0
    LIMIT=100
    while true; do
      RESPONSE=$(curl -sf \
        -H "Authorization: Bearer ${MATRIX_ADMIN_TOKEN}" \
        "${MATRIX_URL}/_synapse/admin/v2/users?from=${FROM}&limit=${LIMIT}&guests=false")

      BATCH=$(echo "$RESPONSE" | jq -r '.users[] | select(.user_type == null) | .name')
      [[ -z "$BATCH" ]] && break
      while IFS= read -r u; do MATRIX_USERS+=("$u"); done <<< "$BATCH"

      NEXT_TOKEN=$(echo "$RESPONSE" | jq -r '.next_token // empty')
      [[ -z "$NEXT_TOKEN" ]] && break
      FROM="$NEXT_TOKEN"
    done

    ok "Number of users in the in Matrix chat: ${#MATRIX_USERS[@]}"
}

# # ======================================================
# # 5. Compare and sync
# # ======================================================

kc_to_matrix_sync() {
    info "=== Strating synchronization ==="

    ENABLED_COUNT=0
    DISABLED_COUNT=0
    ALREADY_OK_COUNT=0
    SKIP_COUNT=0

# # Function: check user status is active or deactivated in Synapse
    get_matrix_user_status() { #active or not
      local mxid="$1"
      curl -sf \
        -H "Authorization: Bearer ${MATRIX_ADMIN_TOKEN}" \
        "${MATRIX_URL}/_synapse/admin/v2/users/${mxid}" \
        | jq -r '.deactivated'
    }

# # Function: deactivate Matrix user (deactivating via MAS)
    deactivate_matrix_user() {
      local mxid="$1"
      mas-cli  manage lock-user --deactivate ${mxid}
      mas-cli  manage kill-sessions ${mxid}
    }

# # # Function: activate (reactivate) Matrix user (activating via MAS)
    activate_matrix_user() {
      local mxid="$1"
      mas-cli manage unlock-user ${mxid}
      mas-cli manage unlock-user --reactivate ${mxid}
    }

# # # ===================================================================================================================
# NOTE: The user activation/deactivation process via the MAS cli runs in both DB (in the MAS DB and in the SYNAPSE DB). #
# # # ===================================================================================================================

# # -- 5a. Users from KeyCloak group -- should be ACTIVE in the Matrix

    check_user_status_in_matrix() {
      info "-- Checking status KeyCloak group users in the Matrix..."
      for kc_user in "${KC_GROUP_MEMBERS[@]}"; do
        mxid="@${kc_user}:${MATRIX_SERVER_NAME}"

        # Check, if user exist in Matrix
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
          -H "Authorization: Bearer ${MATRIX_ADMIN_TOKEN}" \
          "${MATRIX_URL}/_synapse/admin/v2/users/${mxid}")

        if [[ "$HTTP_STATUS" == "404" ]]; then
          warn "  User -- ${mxid} -- exist in KeyCloak, but NOT found in Matrix -- skipping..."
          (( SKIP_COUNT++ )) || true
          continue
        fi

        STATUS=$(get_matrix_user_status "$mxid")

        if [[ "$STATUS" == "true" ]]; then
          info "  Activating: ${kc_user}"
          if $DRY_RUN; then
            warn "  [DRY RUN] activate ${mxid}"
          else
            activate_matrix_user "${kc_user}" && ok "  Activated: ${mxid}" || error "  Activation error: ${mxid}"
          fi
          (( ENABLED_COUNT++ )) || true
        else
          ok "  Already activated: ${mxid}"
          (( ALREADY_OK_COUNT++ )) || true
        fi
      done
    }

    check_user_status_in_matrix

# # -- 5b. Check users on the Matrix side. If the user isn't in the KeyCloak group, deactivate them.
info "-- Checking whether users need to be deactivated in Matrix..."

# lookup-set from KC-users for search
declare -A KC_SET
for u in "${KC_GROUP_MEMBERS[@]}"; do KC_SET["$u"]=1; done

for mxid in "${MATRIX_USERS[@]}"; do
  # Cut localpart: @user:server -- user
  local_part="${mxid#@}"
  local_part="${local_part%:*}"

  # Skip if servers are differrent (federation users)
  mxid_server="${mxid##*:}"
  if [[ "$mxid_server" != "$MATRIX_SERVER_NAME" ]]; then
    continue
  fi

  if [[ -z "${KC_SET[$local_part]+_}" ]]; then
    # User not is in KeyCloak group
    STATUS=$(get_matrix_user_status "$mxid")
    if [[ "$STATUS" == "false" ]]; then
      info "  Deactivating: ${mxid} (user is absent in KeyCloak ${KC_GROUP_NAME} group )"
      if $DRY_RUN; then
        warn "  [DRY RUN] deactivate ${mxid}"
      else
        deactivate_matrix_user "$local_part" && ok "  Diactivated: $local_part" || error "  Deactivation error: $local_part"
      fi
      (( DISABLED_COUNT++ )) || true
    else
      ok "  Already deactivated: ${mxid}"
      (( ALREADY_OK_COUNT++ )) || true
    fi
  fi
done

} # end of kc_to_matrix_sync function

main() {

get_keycloak_token
get_group_id
get_keycloak_group_users
get_matrix_users
kc_to_matrix_sync
}

main
