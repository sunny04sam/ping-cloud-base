#!/usr/bin/env sh

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"

set -ex

templates_dir_path=${STAGING_DIR}/templates/81

# Accept EULA
echo "Accepting the EULA..."
eula_payload=$(envsubst < ${templates_dir_path}/eula.json)
make_initial_api_request -s -X PUT \
    -d "${eula_payload}" \
    "https://localhost:9000/pa-admin-api/v3/users/1" > /dev/null

echo "Changing the default password..."
echo "Change password debugging output suppressed"
set +x

# Change the default password.
# Using set +x to suppress shell debugging
# because it reveals the new admin password
change_password_payload=$(envsubst < ${templates_dir_path}/change_password.json)
make_initial_api_request -s -X PUT \
    -d "${change_password_payload}" \
    "https://localhost:9000/pa-admin-api/v3/users/1/password" > /dev/null

set -x

# Export CONFIG_QUERY_KP_VALID_DAYS so it will get injected into
# config-query-keypair.json.  Default to 365 days.
export CONFIG_QUERY_KP_VALID_DAYS=${CONFIG_QUERY_KP_VALID_DAYS:-365}

echo "Check to see if the Config Query Keypair already exists..."

# Export CONFIG_QUERY_KP_ALIAS so it will get injected into
# config-query-keypair.json.
export CONFIG_QUERY_KP_ALIAS='pingaccess-config-query'
get_config_query_keypair_response=$(make_api_request -s "https://localhost:9000/pa-admin-api/v3/keyPairs")
config_query_keypair=$(jq -n "${get_config_query_keypair_response}" \
    | jq --arg cq_kp_alias "${CONFIG_QUERY_KP_ALIAS}" '.items[] | select(.alias == $cq_kp_alias)')
config_query_keypair_alias=$(jq -n "${config_query_keypair}" | jq -r '.alias')


# Check to see if the keypair already exists.  This can happen if the
# s3 bucket already has configuration in it and the restore runs
# before reaching this script.  The s3 bucket should be clean when
# this runs in production.  Here we're not changing any of the
# configuration in case developers aren't cleaning their buckets out.
# In that case, this script shouldn't change an existing config.
if [ "${config_query_keypair_alias}" = 'null' ]; then

    # Generate a new keypair for the config query listener
    echo "Creating a Config Query KeyPair..."
    config_query_keypair_payload=$(envsubst < ${templates_dir_path}/config-query-keypair.json)
    create_config_query_keypair_response=$(make_api_request -s -d \
        "${config_query_keypair_payload}" \
        "https://localhost:9000/pa-admin-api/v3/keyPairs/generate")

    # Export CONFIG_QUERY_KEYPAIR_ID so it will get injected into
    # config-query.json.
    export CONFIG_QUERY_KEYPAIR_ID=$(jq -n "${create_config_query_keypair_response}" | jq '.id')

    # Retrieving CONFIG QUERY id
    https_listeners_response=$(make_api_request -s "https://localhost:9000/pa-admin-api/v3/httpsListeners")
    config_query_listener_id=$(jq -n "${https_listeners_response}" | jq '.items[] | select(.name=="CONFIG QUERY") | .id')

    # Update CONFIG QUERY HTTPS Listener with with the new keypair
    echo "Updating the Config Query HTTPS Listener with the new KeyPair id..."
    config_query_payload=$(envsubst < ${templates_dir_path}/config-query.json)
    config_query_response=$(make_api_request -s -X PUT \
        -d "${config_query_payload}" \
        "https://localhost:9000/pa-admin-api/v3/httpsListeners/${config_query_listener_id}")

    # Update admin config host
    echo "Updating the host and port of the Admin Config..."
    admin_config_payload=$(envsubst < ${templates_dir_path}/admin-config.json)
    admin_config_response=$(make_api_request -s -X PUT \
        -d "${admin_config_payload}" \
        "https://localhost:9000/pa-admin-api/v3/adminConfig")
else

    echo "Keypair ${CONFIG_QUERY_KP_ALIAS} already exists.  Skipping configuration of the Keypair, the Config Query HTTPS Listener, and the Admin Config."

fi

exit 0