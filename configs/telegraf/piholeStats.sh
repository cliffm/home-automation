#!/bin/bash

# Pi-hole v6 Stats Script for Telegraf
# Based on Reddit solution for Pi-hole v6 API changes

# Pi-hole credentials
PIHOLE_URL="http://192.168.1.65"
PASSWORD="${PIHOLE_PASSWORD}"  # Use environment variable for security

# Authenticate and retrieve SID
SID=$(curl -s -X POST "$PIHOLE_URL/api/auth" \
  -H "accept: application/json" \
  -H "content-type: application/json" \
  -d '{"password":"'"$PASSWORD"'"}' | jq -r '.session.sid')

# Check if SID is obtained
if [ -z "$SID" ] || [ "$SID" = "null" ]; then
  echo "Failed to authenticate with Pi-hole API"
  exit 1
fi

# Fetch metrics/data
STATS=$(curl -s -X GET "$PIHOLE_URL/api/stats/summary" \
  -H "accept: application/json" \
  -H "sid: $SID")
VERSION=$(curl -s -X GET "$PIHOLE_URL/api/info/version" \
  -H "accept: application/json" \
  -H "sid: $SID")
STATUS=$(curl -s -X GET "$PIHOLE_URL/api/dns/blocking" \
  -H "accept: application/json" \
  -H "sid: $SID")

# Parse and format metrics for InfluxDB
queriesTotal=$(echo $STATS | jq '.queries.total')
queriesBlocked=$(echo $STATS | jq '.queries.blocked')
percentBlocked=$(echo $STATS | jq '.queries.percent_blocked')
domainsInList=$(echo $STATS | jq '.gravity.domains_being_blocked')
uniqueClients=$(echo $STATS | jq '.clients.total')
coreLocalHash=$(echo $VERSION | jq -r '.version.core.local.hash')
coreRemoteHash=$(echo $VERSION | jq -r '.version.core.remote.hash')
webLocalHash=$(echo $VERSION | jq -r '.version.web.local.hash')
webRemoteHash=$(echo $VERSION | jq -r '.version.web.remote.hash')
ftlLocalHash=$(echo $VERSION | jq -r '.version.ftl.local.hash')
ftlRemoteHash=$(echo $VERSION | jq -r '.version.ftl.remote.hash')
opStatus=$(echo $STATUS | jq '.blocking')

# Check for updates
if [[ "$coreLocalHash" == "$coreRemoteHash" ]]; then
  coreUpdate="false"
else
  coreUpdate="true"
fi

if [[ "$webLocalHash" == "$webRemoteHash" ]]; then
  webUpdate="false"
else
  webUpdate="true"
fi

if [[ "$ftlLocalHash" == "$ftlRemoteHash" ]]; then
  ftlUpdate="false"
else
  ftlUpdate="true"
fi

# Output in InfluxDB line protocol
echo "pihole_stats queriesBlocked=$queriesBlocked,queriesTotal=$queriesTotal,percentBlocked=$percentBlocked,domainsInList=$domainsInList,uniqueClients=$uniqueClients"
echo "pihole_stats coreUpdate=$coreUpdate,webUpdate=$webUpdate,ftlUpdate=$ftlUpdate"
echo "pihole_stats operationalStatus=$opStatus"

