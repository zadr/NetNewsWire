#!/bin/zsh
# Imports NetNewsWire’s CloudKit schema — record types, and indexes for the fields it queries —
# into the development environment of a team’s containers. Containers that aren’t Ranchero’s
# start with no schema: saves create record types in development, but not the indexes the app’s
# queries need, and production has nothing until a schema is deployed to it.
#
#   CloudKit/import-schema.sh <team-id> <organization-identifier>
#
# Needs a CloudKit management token: make one in CloudKit Console (Settings → Tokens), then
#   xcrun cktool save-token --type management
# To use the schema in production, deploy it from CloudKit Console afterward.
set -euo pipefail
cd "$(dirname "$0")"

TEAM=${1:?team id}
ORG=${2:?organization identifier}

import() {
	local container=$1 file=$2
	xcrun cktool validate-schema --team-id $TEAM --container-id $container --environment development --file $file
	xcrun cktool import-schema --team-id $TEAM --container-id $container --environment development --file $file
	echo "Imported $file into $container (development)"
}

import iCloud.$ORG.NetNewsWire NetNewsWire.ckdb
import iCloud.$ORG.NetNewsWire.Transcripts NetNewsWire.Transcripts.ckdb
