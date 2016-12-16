#!/bin/bash

set -e

# $1            The data to test for an error
function api_errors () {
    echo "$1" | jq -Mr '.ERRORARRAY[] | "API error: " + .ERRORMESSAGE'
    SILENT=$( echo "$1" | jq -e '.ERRORARRAY == []' )
}

function api_call() {
    args=(-d "api_key=$API_TOKEN" -d "api_action=$1") ; shift
    for arg in "$@" ; do
        args+=(--data-urlencode "$arg")
    done
    OUTPUT=$( curl -s -H "Accept: application/json" "${args[@]}" "https://api.linode.com/" )
    api_errors "$OUTPUT"
}

function jqo() {
    echo $OUTPUT | jq -Mje "$@"
}

function wait_jobs() {
    LINODE_ID=$1
    while true ; do
        api_call linode.job.list LinodeID=$LINODE_ID pendingOnly=1
        if ( echo "$OUTPUT" | jq -Mje '.DATA == []' > /dev/null ) ; then
            break
        fi
        sleep 10
    done
}
