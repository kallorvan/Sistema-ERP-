#!/usr/bin/env bash
# Executa os testes SQL de db/tests. Cada arquivo roda em transação e faz ROLLBACK.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
: "${DATABASE_URL:?defina DATABASE_URL}"

for arquivo in "$DIR"/tests/*.sql; do
    echo "== $(basename "$arquivo")"
    psql -X -q -v ON_ERROR_STOP=1 -o /dev/null "$DATABASE_URL" -f "$arquivo" 2>&1 | sed -E "s/^psql:[^ ]+ NOTICE:  /  /"
done
echo "todos os testes passaram."
