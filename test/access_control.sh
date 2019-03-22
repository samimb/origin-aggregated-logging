#!/bin/bash

# test access control
source "$(dirname "${BASH_SOURCE[0]}" )/../hack/lib/init.sh"
source "${OS_O_A_L_DIR}/hack/testing/util.sh"
trap os::test::junit::reconcile_output EXIT
os::util::environment::use_sudo

os::test::junit::declare_suite_start "test/access_control"

LOGGING_NS=${LOGGING_NS:-openshift-logging}

espod=$( get_es_pod es )
esopspod=$( get_es_pod es-ops )
esopspod=${esopspod:-$espod}
es_svc=$( get_es_svc es )
es_ops_svc=$( get_es_svc es-ops )
es_ops_svc=${es_ops_svc:-$es_svc}

# enable debug logging for searchguard and o-e-plugin
#curl_es $es_svc /_cluster/settings -XPUT -d '{"transient":{"logger.com.floragunn.searchguard":"TRACE","logger.io.fabric8.elasticsearch":"TRACE"}}'

delete_users=""
REUSE=${REUSE:-false}

function cleanup() {
    local result_code="$?"
    set +e
    if [ "${REUSE:-false}" = false ] ; then
        for user in $delete_users ; do
            oc delete user $user 2>&1 | artifact_out
        done
    fi
    if [ -n "${espod:-}" ] ; then
        oc exec -c elasticsearch $espod -- es_acl get --doc=roles > $ARTIFACT_DIR/roles
        oc exec -c elasticsearch $espod -- es_acl get --doc=rolesmapping > $ARTIFACT_DIR/rolesmapping
        oc exec -c elasticsearch $espod -- es_acl get --doc=actiongroups > $ARTIFACT_DIR/actiongroups
        oc logs -c elasticsearch $espod > $ARTIFACT_DIR/es.log
        oc exec -c elasticsearch $espod -- logs >> $ARTIFACT_DIR/es.log
        curl_es_pod $espod /project.access-control-* -XDELETE > /dev/null
    fi
    for proj in access-control-1 access-control-2 access-control-3 ; do
        oc delete project $proj 2>&1 | artifact_out
        os::cmd::try_until_failure "oc get project $proj" 2>&1 | artifact_out
    done
    # this will call declare_test_end, suite_end, etc.
    os::test::junit::reconcile_output
    exit $result_code
}

trap cleanup EXIT

function create_user_and_assign_to_projects() {
    local current_project; current_project="$( oc project -q )"
    local user=$1; shift
    local pw=$1; shift
    if oc get users $user > /dev/null 2>&1 ; then
        os::log::info Using existing user $user
    else
        os::log::info Creating user $user with password $pw
        create_users "$user" "$pw" false 2>&1 | artifact_out
        delete_users="$delete_users $user"
    fi
    os::log::info Assigning user to projects "$@"
    while [ -n "${1:-}" ] ; do
        oc project $1 2>&1 | artifact_out
        oc adm policy add-role-to-user view $user 2>&1 | artifact_out
        shift
    done
    oc project "${current_project}" > /dev/null
}

function add_message_to_index() {
    # project is $1
    # message is $2
    # espod is $3
    local project_uuid=$( oc get project $1 -o jsonpath='{ .metadata.uid }' )
    local index="project.$1.$project_uuid.$(date -u +'%Y.%m.%d')"
    local espod=$3
    curl_es_pod "$espod" "/$index/access-control-test/" -XPOST -d '{"message":"'${2:-"access-control message"}'"}' | python -mjson.tool 2>&1 | artifact_out
}

function check_es_acls() {
  local doc=""
  local ts=$( date +%s )
  for doc in roles rolesmapping actiongroups; do
    artifact_log Checking that Elasticsearch pod ${espod} has expected acl definitions $ARTIFACT_DIR/$doc.$ts
    oc exec -c elasticsearch ${espod} -- es_acl get --doc=${doc} > $ARTIFACT_DIR/$doc.$ts 2>&1
  done
}

# test the following
# - regular user can access with token
#   - directly against es
#   - via kibana pod with kibana cert/key
# - regular user cannot access unavailable indices
#   - directly against es
#   - via kibana pod with kibana cert/key
# - regular user cannot access .operations
#   - via es or kibana
#   - with no token
#   - with bogus token
function test_user_has_proper_access() {
    local user=$1; shift
    local pw=$1; shift
    # rest - indices to which access should be granted, followed by --,
    # followed by indices to which access should not be granted
    local expected=1
    local verb=cannot
    local negverb=can
    local nrecs=0
    local kpod=$( get_running_pod kibana )
    local eshost=$( get_es_svc es )
    local esopshost=$( get_es_svc es-ops )
    if [ "$espod" = "$esopspod" ] ; then
        esopshost=$eshost
    fi
    get_test_user_token $user $pw false
    for proj in "$@" ; do
        if [ "$proj" = "--" ] ; then
            expected=0
            verb=can
            negverb=cannot
            continue
        fi
        os::log::info See if user $user $negverb read /project.$proj.*
        os::log::info Checking access directly against ES pod...
        nrecs=$( curl_es_pod_with_token $espod "/project.$proj.*/_count" $test_token | get_count_from_json )
        check_es_acls
        if ! os::cmd::expect_success "test $nrecs = $expected" ; then
            os::log::error $user $verb access project.$proj.* indices from es
            curl_es_pod_with_token $espod "/project.$proj.*/_count" $test_token | python -mjson.tool
            exit 1
        fi
        os::log::info Checking access from Kibana pod...
        nrecs=$( curl_es_from_kibana "$kpod" $eshost "/project.$proj.*/_count" $test_token | get_count_from_json )
        if ! os::cmd::expect_success "test $nrecs = $expected" ; then
            os::log::error $user $verb access project.$proj.* indices from kibana
            curl_es_from_kibana "$kpod" $eshost "/project.$proj.*/_count" $test_token | python -mjson.tool
            exit 1
        fi

        if [ "$expected" = 1 ] ; then
            # make sure no access with incorrect auth
            # bogus token
            os::log::info Checking access providing bogus token
            if ! os::cmd::expect_success_and_text "curl_es_pod_with_token $espod '/project.$proj.*/_count' BOGUS -w '%{response_code}\n'" '401$'; then
                os::log::error invalid access from es with BOGUS token
                curl_es_pod_with_token $espod "/project.$proj.*/_count" BOGUS -v || :
                exit 1
            fi
            if ! os::cmd::expect_success_and_text "curl_es_from_kibana $kpod $eshost '/project.$proj.*/_count' BOGUS -w '%{response_code}\n'" '.*403$'; then
                os::log::error invalid access from kibana with BOGUS token
                curl_es_from_kibana $kpod $eshost "/project.$proj.*/_count" BOGUS -v || :
                exit 1
            fi
            # no token
            os::log::info Checking access providing no username or token
            if ! os::cmd::expect_success_and_text "curl_es_pod_with_token $espod '/project.$proj.*/_count' '' -w '%{response_code}\n'" '401$'; then
                os::log::error invalid access from es with empty token
                curl_es_pod_with_token $espod "/project.$proj.*/_count" "" -v || :
                exit 1
            fi
            if ! os::cmd::expect_success_and_text "curl_es_from_kibana $kpod $eshost '/project.$proj.*/_count' '' -w '%{response_code}\n' -o /dev/null" '403$'; then
                os::log::error invalid access from kibana with empty token
                curl_es_from_kibana $kpod $eshost "/project.$proj.*/_count" "" -v || :
                exit 1
            fi
        fi
    done

    os::log::info See if user $user is denied /.operations.*
    nrecs=$( curl_es_pod_with_token $esopspod "/.operations.*/_count" $test_token | get_count_from_json )
    if ! os::cmd::expect_success "test $nrecs = 0" ; then
        os::log::error $LOG_NORMAL_USER has improper access to .operations.* indices from es
        curl_es_pod_with_token $esopspod "/.operations.*/_count" $test_token | python -mjson.tool
        exit 1
    fi
    esopshost=$( get_es_svc es-ops )
    if [ "$espod" = "$esopspod" ] ; then
        esopshost=$( get_es_svc es )
    fi
    nrecs=$( curl_es_from_kibana "$kpod" "$esopshost" "/.operations.*/_count" $test_token | get_count_from_json )
    if ! os::cmd::expect_success "test $nrecs = 0" ; then
        os::log::error $LOG_NORMAL_USER has improper access to .operations.* indices from kibana
        curl_es_pod_with_token $esopspod "/.operations.*/_count" $test_token | python -mjson.tool
        exit 1
    fi

    os::log::info See if user $user is denied /.operations.* with no token
    os::cmd::expect_success_and_text "curl_es_pod_with_token $esopspod '/.operations.*/_count' '' -w '%{response_code}\n'" '401$'
    os::cmd::expect_success_and_text "curl_es_from_kibana $kpod $esopshost '/.operations.*/_count' '' -w '%{response_code}\n'" '.*403$'

    os::log::info See if user $user is denied /.operations.* with a bogus token
    os::cmd::expect_success_and_text "curl_es_pod_with_token $esopspod '/.operations.*/_count' BOGUS -w '%{response_code}\n'" '401$'
    os::cmd::expect_success_and_text "curl_es_from_kibana $kpod $esopshost '/.operations.*/_count' BOGUS -w '%{response_code}\n'" '.*403$'
}

curl_es_pod $espod /project.access-control-* -XDELETE 2>&1 | artifact_out

for proj in access-control-1 access-control-2 access-control-3 ; do
    os::log::info Creating project $proj
    oc adm new-project $proj --node-selector='' 2>&1 | artifact_out
    os::cmd::try_until_success "oc get project $proj" 2>&1 | artifact_out

    os::log::info Creating test index and entry for $proj
    add_message_to_index $proj "" $espod
done

LOG_ADMIN_USER=${LOG_ADMIN_USER:-admin}
LOG_ADMIN_PW=${LOG_ADMIN_PW:-admin}

# if you ever want to run this test again on the same machine, you'll need to
# use different usernames, otherwise you'll get this odd error:
# # oc login --username=loguser --password=loguser
# error: The server was unable to respond - verify you have provided the correct host and port and that the server is currently running.
# or - set REUSE=true
LOG_NORMAL_USER=${LOG_NORMAL_USER:-loguserac-$RANDOM}
LOG_NORMAL_PW=${LOG_NORMAL_PW:-loguserac-$RANDOM}

LOG_USER2=${LOG_USER2:-loguser2ac-$RANDOM}
LOG_PW2=${LOG_PW2:-loguser2ac-$RANDOM}

create_users $LOG_NORMAL_USER $LOG_NORMAL_PW false $LOG_USER2 $LOG_PW2 false $LOG_ADMIN_USER $LOG_ADMIN_PW true 2>&1 | artifact_out

os::log::info workaround access_control admin failures - sleep 60 seconds to allow system to process cluster role setting
sleep 60
oc auth can-i '*' '*' --user=$LOG_ADMIN_USER 2>&1 | artifact_out
oc get users 2>&1 | artifact_out

create_user_and_assign_to_projects $LOG_NORMAL_USER $LOG_NORMAL_PW access-control-1 access-control-2
create_user_and_assign_to_projects $LOG_USER2 $LOG_PW2 access-control-2 access-control-3

oc login --username=system:admin > /dev/null
oc project ${LOGGING_NS} > /dev/null

test_user_has_proper_access $LOG_NORMAL_USER $LOG_NORMAL_PW access-control-1 access-control-2 -- access-control-3
test_user_has_proper_access $LOG_USER2 $LOG_PW2 access-control-2 access-control-3 -- access-control-1

logging_index=".operations.*"
if [ ${LOGGING_NS} = "logging" ] ; then
  logging_index="project.logging.*"
fi

os::log::info now auth using admin + token
get_test_user_token $LOG_ADMIN_USER $LOG_ADMIN_PW true
if [ ${LOGGING_NS} = "logging" ] && [ $espod != $esopspod] ; then
  nrecs=$( curl_es_pod_with_token $espod "/${logging_index}/_count" $test_token | get_count_from_json )
  os::cmd::expect_success "test $nrecs -gt 1"
fi
nrecs=$( curl_es_pod_with_token $esopspod "/.operations.*/_count" $test_token | get_count_from_json )
os::cmd::expect_success "test $nrecs -gt 1"

os::log::info now see if regular users have access

test_user_has_proper_access $LOG_NORMAL_USER $LOG_NORMAL_PW access-control-1 access-control-2 -- access-control-3
test_user_has_proper_access $LOG_USER2 $LOG_PW2 access-control-2 access-control-3 -- access-control-1

# create a dummy client cert/key - see if we can impersonate kibana with a cert
certdir=$( mktemp -d )
# if oc has the adm ca command then use it
if oc adm --help | grep -q ' ca .*Manage certificates and keys' ; then
    openshift_admin="oc adm"
elif type -p openshift > /dev/null && openshift --help | grep -q '^  admin ' ; then
    openshift_admin="openshift admin"
else
    openshift_admin="oc adm"
fi
$openshift_admin ca create-signer-cert  \
    --key="${certdir}/ca.key" \
    --cert="${certdir}/ca.crt" \
    --serial="${certdir}/ca.serial.txt" \
    --name="logging-signer-$(date +%Y%m%d%H%M%S)" 2>&1 | artifact_out
cat - ${OS_O_A_L_DIR}/hack/testing/signing.conf > $certdir/signing.conf <<CONF
[ default ]
dir                     = ${certdir}               # Top dir
CONF
touch $certdir/ca.db
openssl req -out "$certdir/test.csr" -new -newkey rsa:2048 -keyout "$certdir/test.key" \
    -subj "/CN=system.logging.kibana/OU=OpenShift/O=Logging" -days 712 -nodes 2>&1 | artifact_out
openssl ca \
    -in "$certdir/test.csr" \
    -notext \
    -out "$certdir/test.crt" \
    -config $certdir/signing.conf \
    -extensions v3_req \
    -batch \
    -extensions server_ext 2>&1 | artifact_out

CURL_ES_CERT=$certdir/test.crt CURL_ES_KEY=$certdir/test.key \
    os::cmd::expect_failure "curl_es $es_svc /.kibana/_count"
CURL_ES_CERT=$certdir/test.crt CURL_ES_KEY=$certdir/test.key \
    os::cmd::expect_failure "curl_es $es_svc /project.*/_count"
CURL_ES_CERT=$certdir/test.crt CURL_ES_KEY=$certdir/test.key \
    os::cmd::expect_failure "curl_es $es_ops_svc /.operations.*/_count"
rm -rf $certdir
