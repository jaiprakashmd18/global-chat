#!/usr/bin/env bash
# Runs schema.sql + security tests against a throwaway LOCAL PostgreSQL
# database, using stand-ins for Supabase's auth/realtime schemas.
# Usage: PGUSER=postgres ./tests/local-db/run.sh   (needs psql + a local server)
set -euo pipefail
cd "$(dirname "$0")"
DB=globalchat_test
psql -q -c "drop database if exists $DB" -c "create database $DB"
psql -q -v ON_ERROR_STOP=1 -d $DB -f stubs.sql
psql -q -v ON_ERROR_STOP=1 -d $DB -f ../../schema.sql
psql -d $DB -f security-tests.sql
psql -d $DB -f feature-tests.sql
psql -d $DB -f community-tests.sql
echo "Compare the output with the expectations printed in each --- section."
