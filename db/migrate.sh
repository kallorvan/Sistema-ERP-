#!/usr/bin/env bash
# Aplica as migrations pendentes de db/migrations em ordem, cada uma em sua
# própria transação. Migrations já aplicadas são validadas por checksum.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
: "${DATABASE_URL:?defina DATABASE_URL (ex.: postgres://erp:erp@localhost:5432/erp)}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 "$DATABASE_URL")

"${PSQL[@]}" -c "SET client_min_messages = warning" -c "CREATE TABLE IF NOT EXISTS public.schema_migrations (
    versao      text        PRIMARY KEY,
    checksum    char(64)    NOT NULL,
    aplicado_em timestamptz NOT NULL DEFAULT now())"

for arquivo in "$DIR"/migrations/V*.sql; do
    versao="$(basename "$arquivo" .sql)"
    checksum="$(sha256sum "$arquivo" | cut -d' ' -f1)"
    aplicado="$("${PSQL[@]}" -tAc "SELECT checksum FROM public.schema_migrations WHERE versao = '$versao'")"

    if [[ -n "$aplicado" ]]; then
        if [[ "$aplicado" != "$checksum" ]]; then
            echo "ERRO: $versao foi alterada após aplicada (checksum divergente). Crie uma nova migration." >&2
            exit 1
        fi
        continue
    fi

    echo "aplicando $versao"
    {
        echo "BEGIN;"
        cat "$arquivo"
        echo
        echo "INSERT INTO public.schema_migrations (versao, checksum) VALUES ('$versao', '$checksum');"
        echo "COMMIT;"
    } | "${PSQL[@]}"
done

echo "migrations em dia."
