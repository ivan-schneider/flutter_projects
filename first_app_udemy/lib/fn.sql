-- FUNCTION: graphql_brado.fn_brado_lista_agenda_militar(bigint, timestamp without time zone, timestamp without time zone)

-- DROP FUNCTION IF EXISTS graphql_brado.fn_brado_lista_agenda_militar(bigint, timestamp without time zone, timestamp without time zone);

-- SELECT * FROM graphql_brado.fn_brado_lista_agenda_militar(41657, '2023-07-01','2023-07-31');

CREATE OR REPLACE FUNCTION graphql_brado.fn_brado_lista_agenda_militar_2(
	p_cod_pessoa_servidor bigint,
	p_dat_ini_periodo timestamp without time zone,
	p_dat_fim_periodo timestamp without time zone)
    RETURNS SETOF graphql_brado.ret_brado_lista_agenda_militar_2 
    LANGUAGE 'plpgsql'
    COST 100
    STABLE PARALLEL SAFE 
    ROWS 1000

AS $BODY$
DECLARE
	v_registo record;
	v_num_dias integer := p_dat_fim_periodo::date - p_dat_ini_periodo::date + 1;
	
	v_tipo_alteracao_entrada      	integer   	:= 1;
	v_tipo_alteracao_saida        	integer   	:= 2;
	v_cod_situacao_escala  integer := 1;
	v_cod_situacao_entrada integer := 2;
	
	v_cod_motivo_permuta         	integer[] 	:= ARRAY[25,26];
    v_cod_motivo_prioritaria      	integer   	:= 54;
	v_arr_cod_ala_servico_expediente integer[] 	:= ARRAY[18];
	
	v_alas json;
	v_linha record;
	v_jsonb_lista jsonb := '[]'::jsonb;
	v_dia date;
	v_skip_dia boolean;
	v_flg_na_escala boolean;
BEGIN
	SELECT JSON_AGG( ROW_TO_JSON( t_alas ) )
	INTO v_alas
	FROM (
		SELECT 	p_cod_pessoa_servidor AS cod_pessoa_servidor, 
				d.dia::date AS dia,
				o.cod_orgao,
				o.sgl_orgao,
				lot_ala.cod_ala_servico	AS cod_ala_servico_base,
				COALESCE( alas.cod_grupo_ala, _exp.cod_grupo_ala ) AS cod_grupo_ala, 
				COALESCE( alas.nom_grupo_ala, _exp.nom_grupo_ala ) AS nom_grupo_ala,
				COALESCE( alas.cod_ala_servico, _exp.cod_ala_servico ) AS cod_ala_servico,
				COALESCE( alas.nom_ala_servico, _exp.nom_ala_servico ) AS nom_ala_servico, 
				COALESCE( alas.escala_ala, _exp.escala_ala ) AS escala_ala,
				COALESCE( alas.hor_inicio_turno, _exp.hor_inicio_turno ) AS hor_inicio_turno,
				COALESCE( alas.hor_duracao_turno, _exp.hor_duracao_turno ) AS hor_duracao_turno
		FROM rh.vwm_dados_servidores ts 
		LEFT JOIN ( SELECT generate_series(p_dat_ini_periodo, p_dat_fim_periodo, '1 day'::interval) AS dia ) d
		ON TRUE
		-- 1. Cedidos
		LEFT JOIN graphql_brado.fn_brado_lista_cessao_atual(ts.cod_pessoa_servidor, d.dia::date) AS cessao
		ON cessao.cod_pessoa_servidor = ts.cod_pessoa_servidor
		-- 2. ALA  (por Lotação)
		LEFT JOIN graphql_brado.fn_brado_lista_ala_servico_orgao(ts.cod_pessoa_servidor, d.dia::date) AS lot_ala
		ON lot_ala.cod_pessoa_servidor = ts.cod_pessoa_servidor AND
		   lot_ala.cod_orgao = COALESCE( cessao.cod_orgao, ts.locsit_cod_orgao, ts.orglot_cod_orgao )  AND -- lotacao atual
		   ( cessao.cod_cessao IS NULL AND lot_ala.cod_cessao IS NULL OR
			lot_ala.cod_cessao = cessao.cod_cessao 
		   )
		LEFT JOIN graphql_brado.fn_brado_alas_servico_dias( p_dat_ini_periodo::date, NULL, NULL, v_num_dias ) AS alas
		ON alas.dat_referencia = d.dia::date AND
			alas.cod_ala_servico = lot_ala.cod_ala_servico
		LEFT JOIN ( 
			SELECT ga.cod_grupo_ala, ga.nom_grupo_ala, asv.cod_ala_servico, asv.nom_ala_servico, 
				   ga.nom_grupo_ala ||' - '|| asv.nom_ala_servico AS escala_ala,
				   '13:00:00' AS hor_inicio_turno, '09:00:00' AS hor_duracao_turno, ga.arr_dia_excecao
			FROM operacional.tb_grupo_ala ga
			INNER JOIN operacional.tb_ala_servico asv
			ON asv.cod_grupo_ala = ga.cod_grupo_ala
			WHERE asv.cod_ala_servico = ANY( v_arr_cod_ala_servico_expediente ) 
		) AS _exp
		ON _exp.cod_ala_servico = lot_ala.cod_ala_servico AND 
		   NOT EXTRACT( isodow FROM d.dia::date ) = ANY ( _exp.arr_dia_excecao )		
		LEFT JOIN corporativo.tb_orgao o
		ON o.cod_orgao = COALESCE( cessao.cod_orgao, ts.locsit_cod_orgao, ts.orglot_cod_orgao )
		WHERE ts.cod_pessoa_servidor = p_cod_pessoa_servidor
		ORDER BY 2 ASC
	) AS t_alas;
	

	FOR v_linha IN

	-- 1. ESCALA E SAIU DA ESCALA
		SELECT 	CASE WHEN alt.json_alteracao IS NOT NULL THEN 5 ELSE 1 END AS cod_tipo_evento,  
				CASE WHEN alt.json_alteracao IS NOT NULL THEN 'SAIU' ELSE 'ALA '|| alas.nom_ala_servico END AS sgl_evento, 
				(alas.dia + alas.hor_inicio_turno::interval)::timestamp without time zone AS dat_inicio,
				(alas.dia + alas.hor_inicio_turno::interval + alas.hor_duracao_turno::interval)::timestamp without time zone AS dat_fim,
				alas.cod_grupo_ala,		-- INCLUIDO
				alas.cod_ala_servico,	-- INCLUIDO
				CASE 
					WHEN alt.json_alteracao IS NOT NULL THEN 
						'Alteração de saída ('|| alas.sgl_orgao ||' - Ala: '|| alas.nom_ala_servico ||'): '|| (alt.json_alteracao->0->>'dsc_label') || COALESCE( '; Obs: '||(alt.json_alteracao->0->>'obs_alteracao'), '')
					ELSE
						'Dia  de Serviço ('|| alas.sgl_orgao ||' - Ala: '|| alas.nom_ala_servico ||')'
				END AS dsc_evento,
				CASE WHEN alt.json_alteracao IS NOT NULL THEN 2 ELSE 1 END AS num_prio
		FROM json_to_recordset( v_alas )
		AS  alas(	cod_pessoa_servidor bigint, 
					dia date, 
					cod_orgao integer, 
					sgl_orgao character varying, 
					cod_ala_servico_base integer, 
				 	dat_referencia text, 
					cod_grupo_ala integer, 
					nom_grupo_ala text, 
				 	cod_ala_servico integer, 
				 	nom_ala_servico text, 
				 	escala_ala text, 
				 	hor_inicio_turno text, 
				 	hor_duracao_turno text	)
		LEFT JOIN graphql_brado.fn_brado_lista_json_alteracao( alas.cod_orgao, v_cod_situacao_escala, alas.dia, alas.cod_pessoa_servidor ) AS alt
		ON TRUE 

	UNION ALL

		-- 2. ENTRADA
			SELECT 4 AS cod_tipo_evento, 
				'ALA '|| alas.nom_ala_servico AS sgl_evento, 
				(entrada.dat_inicio_alteracao + alas.hor_inicio_turno::interval)::timestamp without time zone AS dat_inicio,
				(entrada.dat_inicio_alteracao + alas.hor_inicio_turno::interval + alas.hor_duracao_turno::interval)::timestamp without time zone AS dat_fim,
				alas.cod_grupo_ala,		-- INCLUIDO
				alas.cod_ala_servico,	-- INCLUIDO
				CASE WHEN alt.json_alteracao IS NOT NULL THEN 
						CASE WHEN entrada.cod_motivo_alteracao = v_cod_motivo_prioritaria THEN 'Entrada Prioritária (' ELSE 'Alteração de entrada (' END 
						|| o.sgl_orgao ||' - Ala: '|| alas.nom_ala_servico ||'): '|| (alt.json_alteracao->0->>'dsc_label') 
						|| COALESCE( '; Obs: '||(alt.json_alteracao->0->>'obs_alteracao'), '')
					 ELSE
						'Dia  de Serviço ('|| o.sgl_orgao ||' - ALA '|| alas.nom_ala_servico ||')'
				END AS dsc_evento,
				CASE WHEN entrada.cod_motivo_alteracao = v_cod_motivo_prioritaria THEN 31 ELSE 21 END AS num_prio
		FROM operacional.tb_alteracao entrada
		INNER JOIN corporativo.tb_orgao AS o
		ON o.cod_orgao = entrada.cod_lotacao
		INNER JOIN graphql_brado.fn_brado_alas_servico_dia (entrada.dat_inicio_alteracao, NULL, entrada.cod_ala_servico ) alas
		ON alas.cod_ala_servico = entrada.cod_ala_servico
		LEFT JOIN graphql_brado.fn_brado_lista_json_alteracao(entrada.cod_lotacao, v_cod_situacao_entrada, entrada.dat_inicio_alteracao, entrada.cod_pessoa_servidor ) AS alt
		ON TRUE --alt.cod_pessoa_servidor = entrada.cod_pessoa_servidor		
		WHERE
			entrada.cod_tipo_alteracao = v_tipo_alteracao_entrada AND-- Entrada na escala
			entrada.cod_pessoa_servidor = p_cod_pessoa_servidor AND
			entrada.dat_inicio_alteracao BETWEEN p_dat_ini_periodo AND p_dat_fim_periodo AND
			
			entrada.cod_alteracao = (alt.json_alteracao->0->>'cod_alteracao')::integer AND -- exibe apenas a 1a alteração de entrada
			entrada.flg_cancelado IS NOT TRUE AND
			--entrada.cod_ala_servico = ANY ( v_alas ) AND 
			( 
				NOT entrada.cod_motivo_alteracao = ANY( v_cod_motivo_permuta ) OR 
				entrada.cod_usuario_aprovacao IS NOT NULL 
			)
			--entrada.cod_lotacao = COALESCE( cessao.cod_orgao, ts.locsit_cod_orgao, ts.orglot_cod_orgao ) AND  --  entrada na lotação de destino (cod_lotacao)

	UNION ALL
	
	-- 3. FORA DA ESCALA
		SELECT 	6 AS cod_tipo_evento,  
				'SEM' AS sgl_evento, 
				(alas.dia + alas.hor_inicio_turno::interval)::timestamp without time zone AS dat_inicio,
				(alas.dia + alas.hor_inicio_turno::interval + alas.hor_duracao_turno::interval)::timestamp without time zone AS dat_fim,
				alas.sgl_orgao ||': ": Militar sem ala cadastrada na unidade.'AS dsc_evento,
				alas.cod_grupo_ala,		-- INCLUIDO
				alas.cod_ala_servico,	-- INCLUIDO
				3 AS num_prio
		FROM json_to_recordset( v_alas )
		AS  alas(cod_pessoa_servidor bigint, dia date, cod_orgao integer, sgl_orgao character varying, cod_ala_servico_base integer, 
				 dat_referencia text, cod_grupo_ala integer, nom_grupo_ala text, 
				 cod_ala_servico integer, nom_ala_servico text, escala_ala text, hor_inicio_turno text, hor_duracao_turno text	)
		LEFT JOIN graphql_brado.fn_brado_lista_json_afastamento(alas.dia, alas.cod_pessoa_servidor) AS afast
		ON TRUE
		WHERE alas.cod_ala_servico_base IS NULL	-- sem ala de serviço

	UNION ALL

	-- 4. GSV
		SELECT 	2 AS cod_tipo_evento, 
				'GSV' AS sgl_evento,
				tvo.dat_ini_vagas AS dat_inicio,
				tvo.dat_fim_vagas AS dat_fim,
				alas.cod_grupo_ala,		-- INCLUIDO
				alas.cod_ala_servico,	-- INCLUIDO
				'GSV - ' || top.nom_operacao ||' ('|| org_gsv.sgl_orgao ||')' AS dsc_evento,
				11 AS num_prio
		FROM divulgacao_escala.tb_vagas_operacao tvo
		LEFT JOIN divulgacao_escala.tb_operacao top
		ON top.cod_operacao = tvo.cod_operacao_fk		
		LEFT JOIN divulgacao_escala.tb_locais_servico tls
		ON tvo.cod_local_servico_fk = tls.cod_local_servico
		LEFT JOIN corporativo.tb_orgao AS org_gsv
		ON org_gsv.cod_orgao = tls.cod_orgao_fk
		LEFT JOIN  rh.vwm_dados_servidores ts
		ON ts.cod_pessoa_servidor = tvo.cod_pessoa_servidor_fk
		LEFT JOIN divulgacao_escala.tb_turnos tt
		ON tvo.cod_turno_fk = tt.cod_turno
		LEFT JOIN divulgacao_escala.tb_grupos_servico tgs
		ON tgs.cod_grupo_servico = tvo.cod_grupo_servico_fk	
		WHERE 
			tvo.cod_pessoa_servidor_fk = p_cod_pessoa_servidor AND
			tvo.dat_ini_vagas::date BETWEEN p_dat_ini_periodo AND p_dat_fim_periodo
	
	UNION ALL

	-- 5. Afastamentos
		SELECT  afast.cod_tipo_evento,
				afast.sgl_evento, 
				afast.dat_inicio,
				afast.dat_fim,
				alas.cod_grupo_ala,		-- INCLUIDO
				alas.cod_ala_servico,	-- INCLUIDO
				afast.dsc_evento,
				afast.num_prio
		FROM (
			SELECT  	DISTINCT ON(d.dia) d.dia, 
						3 AS cod_tipo_evento, 
						aff.sgl_afastamento AS sgl_evento, 
						d.dia::date + '00:00:00'::interval AS dat_inicio, --aff.dat_inicio_afastamento::timestamp without time zone AS dat_inicio,
						d.dia::date + '23:59:59'::interval AS dat_fim, --aff.dat_termino_afastamento + '23:59:59'::interval AS dat_fim,
						aff.dsc_afastamento AS dsc_evento,
						30 AS num_prio
			FROM (
				SELECT generate_series(p_dat_ini_periodo, p_dat_fim_periodo, '1 day'::interval) AS dia 
			) AS d
			INNER JOIN (
				SELECT
						(ROW_NUMBER () OVER (ORDER BY via_registro DESC, a.dat_inicio_afastamento DESC))::integer AS num_prio,
						--via_registro,
						a.cod_pessoa_servidor, 
						a.dat_inicio_afastamento,
						a.dat_termino_afastamento,
						a.sgl_afastamento,
						a.dsc_afastamento,
						a.flg_incapaz
				FROM graphql_brado.fn_brado_lista_afastamento_periodo(p_cod_pessoa_servidor::integer, p_dat_ini_periodo::date, p_dat_fim_periodo::date) a	
			) AS aff
			ON d.dia::date BETWEEN aff.dat_inicio_afastamento AND aff.dat_termino_afastamento
			
		) AS afast	
		ORDER BY dat_inicio ASC, num_prio DESC
	LOOP
		RAISE NOTICE '%  -  %', v_dia, v_linha.dat_inicio::date;
		IF v_dia != v_linha.dat_inicio::date OR 
		   v_dia IS NULL THEN
			v_dia := v_linha.dat_inicio::date;
			v_skip_dia := false;
			RAISE NOTICE 'Entrou  %', v_dia;
		END IF;
		
		IF v_skip_dia IS FALSE THEN
			v_jsonb_lista := v_jsonb_lista || 
				jsonb_build_object('dat_inicio', v_linha.dat_inicio, 
								   'dat_fim', v_linha.dat_fim, 
								   'cod_tipo_evento', v_linha.cod_tipo_evento, 
								   'dsc_evento', v_linha.dsc_evento, 
								   'sgl_evento', v_linha.sgl_evento,
                                   'cod_grupo_ala', v_linha.cod_grupo_ala,
                                   'cod_ala_servico', v_linha.cod_ala_servico, 
								   'flg_na_escala', v_linha.cod_tipo_evento = ANY( ARRAY[1,11,21,31] ) );
			RAISE NOTICE 'SIM';
		ELSE
			RAISE NOTICE 'NAO';
		END IF;
		
		IF  v_linha.cod_tipo_evento > 29 THEN
			v_skip_dia := true;
		END IF;
	END LOOP;
	
	
	RETURN QUERY
		SELECT  lista.dat_inicio, 
                lista.dat_fim, 
                lista.cod_tipo_evento, 
		        lista.dsc_evento, 
                lista.sgl_evento,
                lista.cod_grupo_ala,
                lista.cod_ala_servico, 
                lista.flg_na_escala
		FROM jsonb_to_recordset( v_jsonb_lista )
		AS  lista(	dat_inicio timestamp without time zone, 
					dat_fim timestamp without time zone, 
					cod_tipo_evento integer, 
				 	dsc_evento text, 
				  	sgl_evento text, 
				  	cod_grupo_ala integer, 
				  	cod_ala_servico integer, 
				  	flg_na_escala boolean);
    RETURN;
END;
$BODY$;

ALTER FUNCTION graphql_brado.fn_brado_lista_agenda_militar(bigint, timestamp without time zone, timestamp without time zone)
    OWNER TO user_brado_graphql;

COMMENT ON FUNCTION graphql_brado.fn_brado_lista_agenda_militar(bigint, timestamp without time zone, timestamp without time zone)
    IS '
Retorna os eventos na agenda do militar: Dias de serviço e afastamentos

Parâmetros: 
	p_cod_pessoa: 
	p_dat_ini_periodo (timestamp without time zone): início do período
	p_dat_fim_periodo (timestamp without time zone): final do período
	
cod_tipo_evento	
	1: Dia de serviço
	2: GSV
	3: Afastamentos
	4: Alterações de entrada
	5: Alterações de saída
 	6: Militar sem ala
	
num_prio
	 1: Dia de serviço
	 2: Alterações de saída
 	 3: Militar sem ala
    30: Afastamentos
	-------------------------------------
	11: GSV
	30: Afastamentos	
	------------------------------------
	21: Alterações de entrada
	30: Afastamentos
	31: Alterações de entrada prioritária
	--------------------------------------
';

-- Type: ret_brado_lista_agenda_militar

-- DROP TYPE IF EXISTS graphql_brado.ret_brado_lista_agenda_militar;

CREATE TYPE graphql_brado.ret_brado_lista_agenda_militar AS
(
	dat_inicio timestamp without time zone,
	dat_fim timestamp without time zone,
	cod_tipo_evento integer,
	dsc_evento text,
	sgl_evento text,
	cod_grupo_ala integer,
	cod_ala_servico integer,
	flg_na_escala boolean
);

ALTER TYPE graphql_brado.ret_brado_lista_agenda_militar
    OWNER TO user_brado_graphql;