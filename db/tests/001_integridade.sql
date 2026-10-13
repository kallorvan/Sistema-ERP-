-- Testes de integridade da fundação. Roda em transação e desfaz tudo no final.
\set ON_ERROR_STOP on
BEGIN;

-- Helper: executa um comando e exige que falhe com o SQLSTATE esperado.
CREATE FUNCTION pg_temp.deve_falhar(p_sql text, p_sqlstate text, p_descricao text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> p_sqlstate THEN
            RAISE EXCEPTION 'FALHOU [%]: esperado SQLSTATE %, obtido % (%)', p_descricao, p_sqlstate, SQLSTATE, SQLERRM;
        END IF;
        RAISE NOTICE 'ok: %', p_descricao;
        RETURN;
    END;
    RAISE EXCEPTION 'FALHOU [%]: comando deveria ter falhado', p_descricao;
END
$$;

CREATE FUNCTION pg_temp.afirmar(p_condicao boolean, p_descricao text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_condicao IS NOT TRUE THEN
        RAISE EXCEPTION 'FALHOU: %', p_descricao;
    END IF;
    RAISE NOTICE 'ok: %', p_descricao;
END
$$;

-- ---------------------------------------------------------------------------
-- Documentos
-- ---------------------------------------------------------------------------
SELECT pg_temp.afirmar(core.fn_valida_cpf('52998224725'),        'CPF válido');
SELECT pg_temp.afirmar(NOT core.fn_valida_cpf('52998224724'),    'CPF com DV errado');
SELECT pg_temp.afirmar(NOT core.fn_valida_cpf('11111111111'),    'CPF repetido');
SELECT pg_temp.afirmar(core.fn_valida_cnpj('11222333000181'),    'CNPJ numérico válido');
SELECT pg_temp.afirmar(NOT core.fn_valida_cnpj('11222333000182'),'CNPJ com DV errado');
SELECT pg_temp.afirmar(core.fn_valida_cnpj('12ABC34501DE35'),    'CNPJ alfanumérico válido (exemplo RFB)');
SELECT pg_temp.afirmar(NOT core.fn_valida_cnpj('12abc34501de35'),'CNPJ alfanumérico minúsculo rejeitado');
SELECT pg_temp.afirmar(NOT core.fn_valida_cnpj('00000000000000'),'CNPJ repetido');

-- UUID v7
SELECT pg_temp.afirmar(substr(core.uuid_v7()::text, 15, 1) = '7', 'uuid_v7 tem versão 7');

-- ---------------------------------------------------------------------------
-- Massa: dois tenants (como owner, sem RLS)
-- ---------------------------------------------------------------------------
INSERT INTO core.tenants (id, nome, slug) VALUES
    ('00000000-0000-7000-8000-00000000000a', 'Tenant A', 'tenant-a'),
    ('00000000-0000-7000-8000-00000000000b', 'Tenant B', 'tenant-b');

INSERT INTO core.usuarios (id, tenant_id, nome, email) VALUES
    ('00000000-0000-7000-8000-0000000000a1', '00000000-0000-7000-8000-00000000000a', 'Ana',   'ana@a.com'),
    ('00000000-0000-7000-8000-0000000000b1', '00000000-0000-7000-8000-00000000000b', 'Bruno', 'bruno@b.com');

INSERT INTO cadastro.unidades_medida (id, tenant_id, sigla, descricao) VALUES
    ('00000000-0000-7000-8000-0000000000a2', '00000000-0000-7000-8000-00000000000a', 'UN', 'Unidade'),
    ('00000000-0000-7000-8000-0000000000b2', '00000000-0000-7000-8000-00000000000b', 'UN', 'Unidade');

-- ---------------------------------------------------------------------------
-- Contexto de aplicação: tenant A, usuária Ana, role erp_app (sujeito a RLS)
-- ---------------------------------------------------------------------------
SET LOCAL app.tenant_id = '00000000-0000-7000-8000-00000000000a';
SET LOCAL app.user_id   = '00000000-0000-7000-8000-0000000000a1';
SET LOCAL ROLE erp_app;

SELECT pg_temp.afirmar((SELECT count(*) FROM core.tenants) = 1,           'RLS: enxerga só o próprio tenant');
SELECT pg_temp.afirmar((SELECT count(*) FROM cadastro.unidades_medida) = 1,'RLS: enxerga só unidades do tenant');

-- tenant_id e created_by preenchidos pelo contexto
INSERT INTO cadastro.produtos (id, codigo, descricao, tipo_item, unidade_id, ncm, preco_venda)
VALUES ('00000000-0000-7000-8000-0000000000a3', 'P001', 'Parafuso', '00',
        '00000000-0000-7000-8000-0000000000a2', '73181500', 0.125);

SELECT pg_temp.afirmar(
    (SELECT tenant_id = '00000000-0000-7000-8000-00000000000a'
        AND created_by = '00000000-0000-7000-8000-0000000000a1'
       FROM cadastro.produtos WHERE codigo = 'P001'),
    'auditoria: tenant_id e created_by preenchidos via contexto');

SELECT pg_temp.afirmar(
    (SELECT preco_venda = 0.125 FROM cadastro.produtos WHERE codigo = 'P001'),
    'preço armazenado exato (NUMERIC)');

-- FK composta: produto do tenant A não pode usar unidade do tenant B
SELECT pg_temp.deve_falhar($$
    INSERT INTO cadastro.produtos (codigo, descricao, tipo_item, unidade_id, ncm)
    VALUES ('P002', 'X', '00', '00000000-0000-7000-8000-0000000000b2', '73181500')$$,
    '23503', 'FK composta bloqueia referência a outro tenant');

-- RLS WITH CHECK: não grava em outro tenant
SELECT pg_temp.deve_falhar($$
    INSERT INTO cadastro.unidades_medida (tenant_id, sigla, descricao)
    VALUES ('00000000-0000-7000-8000-00000000000b', 'KG', 'Quilo')$$,
    '42501', 'RLS bloqueia insert em outro tenant');

-- CHECKs de negócio
SELECT pg_temp.deve_falhar($$
    INSERT INTO cadastro.produtos (codigo, descricao, tipo_item, unidade_id, ncm, preco_venda)
    VALUES ('P003', 'X', '00', '00000000-0000-7000-8000-0000000000a2', '73181500', -1)$$,
    '23514', 'preço negativo rejeitado');
SELECT pg_temp.deve_falhar($$
    INSERT INTO cadastro.produtos (codigo, descricao, tipo_item, unidade_id)
    VALUES ('P004', 'X', '00', '00000000-0000-7000-8000-0000000000a2')$$,
    '23514', 'mercadoria sem NCM rejeitada');
SELECT pg_temp.deve_falhar($$
    INSERT INTO cadastro.produtos (codigo, descricao, tipo_item, unidade_id, ncm)
    VALUES ('P001', 'Duplicado', '00', '00000000-0000-7000-8000-0000000000a2', '73181500')$$,
    '23505', 'código de produto duplicado no tenant');
SELECT pg_temp.deve_falhar($$
    INSERT INTO cadastro.parceiros (codigo, tipo_pessoa, documento, nome, eh_cliente)
    VALUES ('C001', 'J', '11222333000182', 'Cliente', true)$$,
    '23514', 'parceiro PJ com CNPJ inválido');
SELECT pg_temp.deve_falhar($$
    INSERT INTO cadastro.parceiros (codigo, tipo_pessoa, documento, nome)
    VALUES ('C002', 'F', '52998224725', 'Sem papel')$$,
    '23514', 'parceiro sem papel (cliente/fornecedor/transp.)');

INSERT INTO cadastro.parceiros (codigo, tipo_pessoa, documento, nome, eh_cliente)
VALUES ('C003', 'J', '12ABC34501DE35', 'Cliente Alfanumérico', true);

-- Imutabilidade de tenant_id
SELECT pg_temp.deve_falhar($$
    UPDATE cadastro.produtos SET tenant_id = '00000000-0000-7000-8000-00000000000b' WHERE codigo = 'P001'$$,
    '23000', 'tenant_id imutável (trigger de auditoria)');

-- Sem DELETE físico para a aplicação
SELECT pg_temp.deve_falhar($$DELETE FROM cadastro.produtos WHERE codigo = 'P001'$$,
    '42501', 'aplicação não tem DELETE (exclusão lógica)');

-- Atualização gera log com campos alterados
UPDATE cadastro.produtos SET preco_venda = 0.15 WHERE codigo = 'P001';
SELECT pg_temp.afirmar(
    (SELECT campos_alterados = ARRAY['preco_venda'] AND alterado_por = '00000000-0000-7000-8000-0000000000a1'
       FROM core.audit_log
      WHERE tabela = 'cadastro.produtos' AND operacao = 'U'
        AND registro_id = '00000000-0000-7000-8000-0000000000a3'),
    'audit_log registra campos alterados e autor');

-- Aplicação não forja o log
SELECT pg_temp.deve_falhar($$INSERT INTO core.audit_log (tabela, operacao) VALUES ('x', 'I')$$,
    '42501', 'audit_log não aceita insert direto');

RESET ROLE;

-- Imutabilidade de created_by (mesmo como owner)
SELECT pg_temp.deve_falhar($$
    UPDATE cadastro.produtos SET created_by = NULL WHERE codigo = 'P001'$$,
    '23000', 'created_by imutável');

-- Resolução de tenant no login
SELECT pg_temp.afirmar(core.fn_resolver_tenant('TENANT-A') = '00000000-0000-7000-8000-00000000000a',
    'fn_resolver_tenant por slug (case-insensitive)');

ROLLBACK;
