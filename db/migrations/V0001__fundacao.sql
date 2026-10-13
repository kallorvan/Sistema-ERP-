-- =============================================================================
-- V0001 - Fundação: extensões, schemas, roles, domínios e funções utilitárias
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS cadastro;

-- Role usado pela aplicação. Sem BYPASSRLS, sem ownership: fica sujeito ao RLS.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'erp_app') THEN
        CREATE ROLE erp_app NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA core, cadastro TO erp_app;

-- -----------------------------------------------------------------------------
-- Domínios numéricos exatos (NUNCA float para dinheiro/quantidade)
-- -----------------------------------------------------------------------------
CREATE DOMAIN core.dinheiro       AS NUMERIC(18,2);
CREATE DOMAIN core.valor_unitario AS NUMERIC(18,6);
CREATE DOMAIN core.quantidade     AS NUMERIC(18,6);
-- Alíquotas podem passar de 100% (ex.: IPI de alguns produtos), por isso só >= 0.
CREATE DOMAIN core.aliquota       AS NUMERIC(9,4) CHECK (VALUE >= 0);

CREATE DOMAIN core.uf AS CHAR(2) CHECK (VALUE IN (
    'AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA',
    'PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO','EX'));

CREATE DOMAIN core.cep              AS CHAR(8) CHECK (VALUE ~ '^[0-9]{8}$');
CREATE DOMAIN core.codigo_ibge_munic AS CHAR(7) CHECK (VALUE ~ '^[0-9]{7}$');

-- -----------------------------------------------------------------------------
-- UUID v7 (ordenável por tempo -> índices B-tree mais compactos que v4)
-- -----------------------------------------------------------------------------
CREATE FUNCTION core.uuid_v7() RETURNS uuid
LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
    SELECT encode(
        set_bit(set_bit(
            overlay(uuid_send(gen_random_uuid())
                    PLACING substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
                    FROM 1 FOR 6),
        52, 1), 53, 1),
    'hex')::uuid;
$$;

-- -----------------------------------------------------------------------------
-- Contexto da sessão (definido pela aplicação com SET LOCAL a cada transação)
-- -----------------------------------------------------------------------------
CREATE FUNCTION core.current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid;
$$;

CREATE FUNCTION core.current_user_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT NULLIF(current_setting('app.user_id', true), '')::uuid;
$$;

-- -----------------------------------------------------------------------------
-- Validação de documentos
-- -----------------------------------------------------------------------------
CREATE FUNCTION core.fn_valida_cpf(p_cpf text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    v_soma int;
    v_dv1  int;
    v_dv2  int;
BEGIN
    IF p_cpf !~ '^[0-9]{11}$' OR p_cpf ~ '^(\d)\1{10}$' THEN
        RETURN false;
    END IF;

    v_soma := 0;
    FOR i IN 1..9 LOOP
        v_soma := v_soma + substr(p_cpf, i, 1)::int * (11 - i);
    END LOOP;
    v_dv1 := (v_soma * 10 % 11) % 10;

    v_soma := 0;
    FOR i IN 1..10 LOOP
        v_soma := v_soma + substr(p_cpf, i, 1)::int * (12 - i);
    END LOOP;
    v_dv2 := (v_soma * 10 % 11) % 10;

    RETURN v_dv1 = substr(p_cpf, 10, 1)::int AND v_dv2 = substr(p_cpf, 11, 1)::int;
END
$$;

-- CNPJ numérico e alfanumérico (IN RFB 2.229/2024, vigente a partir de jul/2026):
-- 12 posições [0-9A-Z] + 2 DVs numéricos; valor de cada caractere = ASCII - 48.
-- Exige maiúsculas e sem máscara (normalização é responsabilidade da aplicação).
CREATE FUNCTION core.fn_valida_cnpj(p_cnpj text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    c_pesos1 CONSTANT int[] := '{5,4,3,2,9,8,7,6,5,4,3,2}';
    c_pesos2 CONSTANT int[] := '{6,5,4,3,2,9,8,7,6,5,4,3,2}';
    v_soma int;
    v_resto int;
    v_dv1 int;
    v_dv2 int;
BEGIN
    IF p_cnpj !~ '^[0-9A-Z]{12}[0-9]{2}$' OR p_cnpj ~ '^(\d)\1{13}$' THEN
        RETURN false;
    END IF;

    v_soma := 0;
    FOR i IN 1..12 LOOP
        v_soma := v_soma + (ascii(substr(p_cnpj, i, 1)) - 48) * c_pesos1[i];
    END LOOP;
    v_resto := v_soma % 11;
    v_dv1 := CASE WHEN v_resto < 2 THEN 0 ELSE 11 - v_resto END;

    v_soma := 0;
    FOR i IN 1..13 LOOP
        v_soma := v_soma + (ascii(substr(p_cnpj, i, 1)) - 48) * c_pesos2[i];
    END LOOP;
    v_resto := v_soma % 11;
    v_dv2 := CASE WHEN v_resto < 2 THEN 0 ELSE 11 - v_resto END;

    RETURN v_dv1 = substr(p_cnpj, 13, 1)::int AND v_dv2 = substr(p_cnpj, 14, 1)::int;
END
$$;

-- -----------------------------------------------------------------------------
-- Trigger de colunas de auditoria
--   TG_ARGV[0] = 'tenant' (tabela multi-tenant) | 'global'
-- -----------------------------------------------------------------------------
CREATE FUNCTION core.fn_colunas_auditoria() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := now();
        NEW.updated_at := now();
        NEW.created_by := COALESCE(NEW.created_by, core.current_user_id());
        NEW.updated_by := NEW.created_by;
        IF TG_ARGV[0] = 'tenant' THEN
            NEW.tenant_id := COALESCE(NEW.tenant_id, core.current_tenant_id());
            IF NEW.tenant_id IS NULL THEN
                RAISE EXCEPTION 'tenant_id não informado e app.tenant_id não definido (%.%)',
                    TG_TABLE_SCHEMA, TG_TABLE_NAME
                    USING ERRCODE = 'not_null_violation';
            END IF;
        END IF;
    ELSE
        IF NEW.created_at IS DISTINCT FROM OLD.created_at
           OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            RAISE EXCEPTION 'created_at/created_by são imutáveis (%.%)', TG_TABLE_SCHEMA, TG_TABLE_NAME
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF TG_ARGV[0] = 'tenant' AND NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
            RAISE EXCEPTION 'tenant_id é imutável (%.%)', TG_TABLE_SCHEMA, TG_TABLE_NAME
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        NEW.updated_at := now();
        NEW.updated_by := COALESCE(core.current_user_id(), NEW.updated_by);
    END IF;
    RETURN NEW;
END
$$;

-- -----------------------------------------------------------------------------
-- Log de auditoria (append-only)
-- -----------------------------------------------------------------------------
CREATE TABLE core.audit_log (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        uuid,
    tabela           text        NOT NULL,
    registro_id      uuid,
    operacao         char(1)     NOT NULL CHECK (operacao IN ('I','U','D')),
    dados_antigos    jsonb,
    dados_novos      jsonb,
    campos_alterados text[],
    alterado_por     uuid,
    alterado_em      timestamptz NOT NULL DEFAULT now(),
    transacao_id     bigint      NOT NULL DEFAULT txid_current()
);

CREATE INDEX audit_log_registro_ix ON core.audit_log (tenant_id, tabela, registro_id, alterado_em);
CREATE INDEX audit_log_data_brin   ON core.audit_log USING brin (alterado_em);

ALTER TABLE core.audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY isolamento_tenant ON core.audit_log
    FOR SELECT USING (tenant_id = core.current_tenant_id());
GRANT SELECT ON core.audit_log TO erp_app;  -- sem INSERT/UPDATE/DELETE direto

CREATE FUNCTION core.fn_audit_log() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, core AS $$
DECLARE
    v_antigo jsonb;
    v_novo   jsonb;
    v_linha  jsonb;
    v_campos text[];
BEGIN
    IF TG_OP IN ('UPDATE','DELETE') THEN v_antigo := to_jsonb(OLD); END IF;
    IF TG_OP IN ('INSERT','UPDATE') THEN v_novo   := to_jsonb(NEW); END IF;
    v_linha := COALESCE(v_novo, v_antigo);

    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(n.key ORDER BY n.key) INTO v_campos
          FROM jsonb_each(v_novo) n
         WHERE n.value IS DISTINCT FROM v_antigo -> n.key
           AND n.key NOT IN ('updated_at','updated_by');
        IF v_campos IS NULL THEN
            RETURN NULL;  -- nada relevante mudou
        END IF;
    END IF;

    INSERT INTO core.audit_log
        (tenant_id, tabela, registro_id, operacao, dados_antigos, dados_novos, campos_alterados, alterado_por)
    VALUES (
        CASE WHEN TG_TABLE_SCHEMA = 'core' AND TG_TABLE_NAME = 'tenants'
             THEN (v_linha ->> 'id')::uuid
             ELSE (v_linha ->> 'tenant_id')::uuid END,
        TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
        (v_linha ->> 'id')::uuid,
        left(TG_OP, 1),
        v_antigo,
        v_novo,
        v_campos,
        core.current_user_id()
    );
    RETURN NULL;
END
$$;
