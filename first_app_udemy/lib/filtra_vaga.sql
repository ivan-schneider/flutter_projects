-- FUNCTION: divulgacao_escala.fn_filtra_vagas_disponiveis(integer[], integer)

-- DROP FUNCTION IF EXISTS divulgacao_escala.fn_filtra_vagas_disponiveis(integer[], integer);

CREATE OR REPLACE FUNCTION divulgacao_escala.fn_filtra_vagas_disponiveis(
	p_arr_cod_vaga integer[],
	p_cod_pessoa integer)
    RETURNS integer[]
    LANGUAGE 'plpgsql'
    COST 100
    STABLE PARALLEL UNSAFE
AS $BODY$
DECLARE
	v_arr_cod_vaga integer[];
	v_dat_ini_vagas timestamp;
	v_dat_fim_vagas timestamp;
	v_cod_periodo_inscricao integer;
	-- VARIÁVEL USADA PARA OS LOOPS FOR
	v_record record;
	-- VARIÁVEIS PARA IDENTIFICAR VAGAS SEQUENCIAIS
	v_dat_ini_vaga_sequencial timestamp;
	v_dat_fim_vaga_sequencial timestamp;
	v_qtd_gsv_sequencial integer;
	-- INFORMAÇÕES DO SERVIDOR
	v_cod_ala_servico integer;
	v_cod_grupo_ala integer;
	-- VARIÁVEIS DE CONFIGURACAÇÃO
	v_json_parans_conf json;
	v_intervalo_antes_servico interval;
	v_intervalo_apos_servico interval;
	v_intervalo_hora_max_gsv_sequencial_permitida interval;
	v_quantidade_gsv_sequencial_permitida integer;
	v_intervalo_gsv_gsv_mesmo_local_hora real;
	v_intervalo_gsv_gsv_mesmo_local_minuto real;
	v_intervalo_gsv_gsv_outro_local_hora real;
	v_intervalo_gsv_gsv_outro_local_minuto real;
BEGIN
	/*---------------------------------------------------------------------------------------------------------
	DESCRIÇÃO: A partir de um array de vagas inicial e de um periodo especificado, retorna a lista de vagas que
		não apresentam nenhum conflito com datas de serviço, baixas no consul, impedimentos no GSV-WEB e outras
		vagas de GSV já marcadas
	PARÂMETROS: 
		>> p_arr_cod_vaga: Array inicial de vagas
		>> p_cod_pessoa: militar que está concorrendo às vagas
	RETORNO
		>> array de vagas que não apresenta nenhum conflito
	---------------------------------------------------------------------------------------------------------*/
	-- INICIALIZAÇÃO 
	-- Vagas disponíveis
	v_arr_cod_vaga := p_arr_cod_vaga;
	
	-- DATAS DE REFERÊNCIA
	-- ACRESCENTA MARGEM DE SEGURANÇA POR CAUSA DOS INTERVALOS DE DESCANSO (+ OU - 24H)
	SELECT 
		MIN(dat_ini_vagas) - '24 HOURS'::interval, 
		MAX(dat_fim_vagas) + '24 HOURS'::interval
	INTO 
		v_dat_ini_vagas,
		v_dat_fim_vagas	
	-- DADOS DA VAGA
	FROM divulgacao_escala.tb_vagas_operacao tvo
	WHERE tvo.cod_vaga_operacao = ANY(v_arr_cod_vaga);

	-- Obter cod_periodo_inscricao das vagas
	SELECT tpi.cod_periodo_inscricao
	INTO v_cod_periodo_inscricao
	FROM divulgacao_escala.tb_vagas_operacao tvo	
	-- DADOS DA OPERAÇÃO 
	LEFT JOIN divulgacao_escala.tb_operacao top ON tvo.cod_operacao_fk = top.cod_operacao
	-- PERIODO INSCRIÇÃO
	LEFT JOIN divulgacao_escala.tb_operacao_fase_periodo_inscricao tofpi ON top.cod_operacao = tofpi.cod_operacao_fk
	INNER JOIN divulgacao_escala.tb_fases_periodo_inscricao tfpi 
		ON (tofpi.cod_tipo_fase_inscricao_fk = tfpi.cod_tipo_fase_inscricao_fk AND
			tofpi.cod_periodo_inscricao_fk = tfpi.cod_periodo_inscricao_fk)
	INNER JOIN divulgacao_escala.tb_periodo_inscricao tpi
		ON (tpi.cod_periodo_inscricao = tfpi.cod_periodo_inscricao_fk AND
			tpi.flg_arquivado IS FALSE	AND
			(
				(
					tpi.dat_limite_liberacao IS NOT NULL AND
					tvo.dat_ini_vagas BETWEEN tpi.dat_limite_liberacao AND tpi.dat_fim_periodo_validade_inscricao
				) OR 
				(
					tpi.dat_limite_liberacao IS NULL AND
					tvo.dat_ini_vagas BETWEEN tpi.dat_ini_periodo_validade_inscricao AND tpi.dat_fim_periodo_validade_inscricao
				)
			))		
	WHERE tvo.cod_vaga_operacao = ANY(v_arr_cod_vaga) 
	GROUP BY tpi.cod_periodo_inscricao
	LIMIT 1;

	-- Obter ALA do militar
	SELECT 
		tsaga.cod_grupo_ala_fk,
		tsaga.cod_ala_servico_fk
	INTO 
		v_cod_grupo_ala,
		v_cod_ala_servico
	FROM rh.tb_servidor ts
	LEFT JOIN divulgacao_escala.tb_servidor_ala_grupo_ala tsaga
		ON ts.cod_pessoa_servidor = tsaga.cod_servidor_fk
	WHERE ts.cod_pessoa_servidor = p_cod_pessoa
	GROUP BY 1,2;

	SELECT 
		tsca.cod_grupo_ala_fk,
		tsca.cod_ala_servico_fk
	INTO 
		v_cod_grupo_ala,
		v_cod_ala_servico
	FROM divulgacao_escala.tb_periodo_inscricao tpi
	LEFT JOIN divulgacao_escala.tb_servidor_candidato_periodo_inscricao tscpi
		ON tpi.cod_periodo_inscricao = tscpi.cod_periodo_inscricao_fk
	LEFT JOIN divulgacao_escala.tb_servidor_candidato tsc 
		ON tscpi.cod_servidor_candidato_fk = tsc.cod_servidor_candidato
	LEFT JOIN divulgacao_escala.tb_servidor_candidato_alas tsca 
		ON tsc.cod_servidor_candidato = tsca.cod_servidor_candidato_fk
	WHERE tpi.cod_periodo_inscricao = v_cod_periodo_inscricao AND
		tsc.cod_pessoa_servidor_fk = p_cod_pessoa
	LIMIT 1;

	-- Parâmetros de configuração
	v_json_parans_conf := divulgacao_escala.fn_get_config_sistema(v_cod_grupo_ala);
	--RAISE NOTICE 'fn_filtra_vagas_disponiveis - v_json_parans_conf: %', v_json_parans_conf;
	v_intervalo_antes_servico := (v_json_parans_conf::json->>'intervalo_antes_servico')::interval;
	v_intervalo_apos_servico := (v_json_parans_conf::json->>'intervalo_apos_servico')::interval;
	v_intervalo_hora_max_gsv_sequencial_permitida := (v_json_parans_conf::json->>'intervalo_hora_max_gsv_sequencial_permitida')::interval;
	v_quantidade_gsv_sequencial_permitida := (v_json_parans_conf::json->>'quantidade_gsv_sequencial_permitida')::integer;
	v_intervalo_gsv_gsv_mesmo_local_hora := (v_json_parans_conf::json->>'intervalo_gsv_gsv_mesmo_local_hora')::real;
	v_intervalo_gsv_gsv_mesmo_local_minuto := (v_json_parans_conf::json->>'intervalo_gsv_gsv_mesmo_local_minuto')::real;
	v_intervalo_gsv_gsv_outro_local_hora := (v_json_parans_conf::json->>'intervalo_gsv_gsv_outro_local_hora')::real;
	v_intervalo_gsv_gsv_outro_local_minuto := (v_json_parans_conf::json->>'intervalo_gsv_gsv_outro_local_minuto')::real;

	-- RESTRIÇOES: DIAS DE SERVIÇO, VAGAS JÁ MARCADAS, BAIXAS NO GSVWEB, BAIXAS NO CONSUL
	FOR v_record IN
		SELECT 
			cod_local_servico ,
			dat_ini_restricao_mesmo_local, 
			dat_fim_restricao_mesmo_local, 
			dat_ini_restricao_outro_local, 
			dat_fim_restricao_outro_local
		FROM 
		(
			-- DIAS QUE O MILITAR ESTÁ DE SERVIÇO + PERIODO DE DESCANSO ANTES E APÓS O SERVIÇO
			SELECT 
				NULL::integer AS cod_local_servico,
				dat_inicio_servico - v_intervalo_antes_servico AS dat_ini_restricao_mesmo_local, 
				dat_termino_servico + v_intervalo_apos_servico AS dat_fim_restricao_mesmo_local,
				NULL::timestamp AS dat_ini_restricao_outro_local, 
				NULL::timestamp AS dat_fim_restricao_outro_local
			FROM divulgacao_escala.tb_data_ala_servico tdas
			WHERE 
				cod_ala_servico_fk = v_cod_ala_servico AND 
				cod_grupo_ala_servico_fk = v_cod_grupo_ala AND
				(
					(dat_inicio_servico - v_intervalo_antes_servico) BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR 
					(dat_termino_servico + v_intervalo_apos_servico) BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR
					(
						(dat_inicio_servico - v_intervalo_antes_servico) < v_dat_ini_vagas AND
						(dat_termino_servico + v_intervalo_apos_servico) > v_dat_fim_vagas
					)
				)
			UNION ALL 
			-- DIAS EM QUE O MILITAR JÁ ESTÁ DE GSV + PERIODO DE DESCANSO ANTES E APÓS A GSV
			-- DESCANSO VARIA PARA O MESMO LOCAL E PARA UM LOCAL DIFERENTE
			SELECT 
				cod_local_servico_fk AS cod_local_servico,
				(CASE
					-- Vaga acumula 2 ou 3 cotas de GSV AND expediente
					WHEN ttt.multiplicador_pagamento > 1 AND  v_cod_grupo_ala = 6 THEN 
						tvo.dat_ini_vagas - (ttt.hora_intervalo_antes_expediente || ' HOURS')::interval 	
					-- Vaga acumula 2 ou 3 cotas de GSV AND operacional
					WHEN ttt.multiplicador_pagamento > 1 AND   v_cod_grupo_ala != 6 THEN 
						tvo.dat_ini_vagas - (ttt.hora_intervalo_antes_prontidao || ' HOURS')::interval 
					-- Vaga com uma cota apenas
					ELSE 
						tvo.dat_ini_vagas - (v_intervalo_gsv_gsv_mesmo_local_hora|| ' HOURS')::interval 
						- (v_intervalo_gsv_gsv_mesmo_local_minuto || ' MINUTES')::interval 
				END)  AS dat_ini_restricao_mesmo_local, 
				(CASE
					-- Vaga acumula 2 ou 3 cotas de GSV AND expediente
					WHEN ttt.multiplicador_pagamento > 1 AND  v_cod_grupo_ala= 6 THEN 
						tvo.dat_fim_vagas + (ttt.hora_intervalo_depois_expediente || ' HOURS')::interval 	
					-- Vaga acumula 2 ou 3 cotas de GSV AND operacional
					WHEN ttt.multiplicador_pagamento > 1 AND   v_cod_grupo_ala != 6 THEN 
						tvo.dat_fim_vagas + (ttt.hora_intervalo_depois_prontidao || ' HOURS')::interval 
					-- Vaga com uma cota apenas
					ELSE 
						tvo.dat_fim_vagas + (v_intervalo_gsv_gsv_mesmo_local_hora || ' HOURS')::interval 
						+ (v_intervalo_gsv_gsv_mesmo_local_minuto|| ' MINUTES')::interval 
				END)  AS dat_fim_restricao_mesmo_local, 
				(CASE
					-- Vaga acumula 2 ou 3 cotas de GSV AND expediente
					WHEN ttt.multiplicador_pagamento > 1 AND  v_cod_grupo_ala = 6 THEN 
						tvo.dat_ini_vagas - (ttt.hora_intervalo_antes_expediente || ' HOURS')::interval 	
					-- Vaga acumula 2 ou 3 cotas de GSV AND operacional
					WHEN ttt.multiplicador_pagamento > 1 AND   v_cod_grupo_ala != 6 THEN 
						tvo.dat_ini_vagas - (ttt.hora_intervalo_antes_prontidao || ' HOURS')::interval 
					-- Vaga com uma cota apenas
					ELSE 
						tvo.dat_ini_vagas - (v_intervalo_gsv_gsv_outro_local_hora|| ' HOURS')::interval 
						- (v_intervalo_gsv_gsv_outro_local_minuto || ' MINUTES')::interval 
				END)  AS dat_ini_restricao_outro_local, 
				(CASE
					-- Vaga acumula 2 ou 3 cotas de GSV AND expediente
					WHEN ttt.multiplicador_pagamento > 1 AND  v_cod_grupo_ala = 6 THEN 
						tvo.dat_fim_vagas + (ttt.hora_intervalo_depois_expediente || ' HOURS')::interval 	
					-- Vaga acumula 2 ou 3 cotas de GSV AND operacional
					WHEN ttt.multiplicador_pagamento > 1 AND   v_cod_grupo_ala != 6 THEN 
						tvo.dat_fim_vagas + (ttt.hora_intervalo_depois_prontidao || ' HOURS')::interval 
					-- Vaga com uma cota apenas
					ELSE 
						tvo.dat_fim_vagas + (v_intervalo_gsv_gsv_outro_local_hora || ' HOURS')::interval 
						+ (v_intervalo_gsv_gsv_outro_local_minuto || ' MINUTES')::interval 
				END)  AS dat_fim_restricao_outro_local
			FROM divulgacao_escala.tb_vagas_operacao tvo
			LEFT JOIN divulgacao_escala.tb_turnos tt
				ON tvo.cod_turno_fk = tt.cod_turno
			LEFT JOIN divulgacao_escala.tb_tipo_turno ttt
				ON tt.cod_tipo_turno_fk = ttt.cod_tipo_turno
			WHERE
				tvo.cod_pessoa_servidor_fk = p_cod_pessoa AND 
				(
					dat_ini_vagas BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR 
					dat_fim_vagas BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR 
					(
						dat_ini_vagas < v_dat_ini_vagas AND
						dat_fim_vagas > v_dat_fim_vagas
					)
				)
			UNION ALL 
			-- AFASTAMENTSO CADASTRADOS NO PRÓPRIO GSVWEB
			SELECT 
				NULL AS cod_local_servico,
				dat_ini_afastamento_candidato AS dat_ini_restricao_mesmo_local, 
				dat_fim_afastamento_candidato AS dat_fim_restricao_mesmo_local,
				NULL AS dat_ini_restricao_outro_local, 
				NULL AS dat_fim_restricao_outro_local
			FROM divulgacao_escala.tb_afastamentos_candidato 
			WHERE 
				cod_pessoa_servidor_fk = p_cod_pessoa AND
				dat_ini_afastamento_candidato <= dat_fim_afastamento_candidato AND 
				(
					dat_ini_afastamento_candidato BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR 
					dat_fim_afastamento_candidato BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR
					(
						dat_ini_afastamento_candidato < v_dat_ini_vagas AND 
						dat_fim_afastamento_candidato > v_dat_fim_vagas
					)
				)
			UNION ALL 
			-- AFASTAMENTOS CADASTRADOS NO CONSUL
			SELECT 
				NULL AS cod_local_servico,
				((dat_inicio_afastamento)::text || ' 00:00:00')::timestamp AS dat_ini_restricao_mesmo_local, 
				((dat_inicio_afastamento + qtd_dias)::text  || ' 23:59:59')::timestamp AS dat_fim_restricao_mesmo_local,
				NULL AS dat_ini_restricao_outro_local, 
				NULL AS dat_fim_restricao_outro_local
			FROM rh.tb_afastamento_servidor tafs
			WHERE 
				cod_pessoa_servidor = p_cod_pessoa AND
				cod_motivo_remarcacao IS NULL AND		
				cod_motivo_interrupcao IS NULL AND 
				(
					((dat_inicio_afastamento)::text || ' 00:00:00')::timestamp 				BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR 
					((dat_inicio_afastamento + qtd_dias)::text  || ' 23:59:59')::timestamp 	BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR
					(
						((dat_inicio_afastamento)::text || ' 00:00:00')::timestamp < v_dat_ini_vagas AND 
						((dat_inicio_afastamento + qtd_dias)::text  || ' 23:59:59')::timestamp > v_dat_fim_vagas
					)
				)
		) AS tb_restricao_data
	LOOP	
		IF v_record.cod_local_servico IS NOT NULL THEN 
			SELECT ARRAY_AGG(cod_vaga_operacao)
			INTO v_arr_cod_vaga
			FROM  divulgacao_escala.tb_vagas_operacao
			WHERE cod_vaga_operacao = ANY(v_arr_cod_vaga) AND
				((
					v_record.cod_local_servico = cod_local_servico_fk AND NOT 
					(
						(dat_ini_vagas > v_record.dat_ini_restricao_mesmo_local AND dat_ini_vagas < v_record.dat_fim_restricao_mesmo_local) OR
						(dat_fim_vagas > v_record.dat_ini_restricao_mesmo_local AND dat_fim_vagas < v_record.dat_fim_restricao_mesmo_local) OR
						(
							dat_ini_vagas < v_record.dat_ini_restricao_mesmo_local AND 
							dat_fim_vagas > v_record.dat_fim_restricao_mesmo_local 
						)
					)
				)OR
				(
					v_record.cod_local_servico !=  cod_local_servico_fk AND NOT
					(
						(dat_ini_vagas > v_record.dat_ini_restricao_outro_local AND dat_ini_vagas < v_record.dat_fim_restricao_outro_local) OR
						(dat_fim_vagas > v_record.dat_ini_restricao_outro_local AND dat_fim_vagas < v_record.dat_fim_restricao_outro_local) OR
						(
							dat_ini_vagas < v_record.dat_ini_restricao_outro_local AND 	
							dat_fim_vagas > v_record.dat_fim_restricao_outro_local
						)
					)
				));	
		ELSE
			SELECT ARRAY_AGG(cod_vaga_operacao)
			INTO v_arr_cod_vaga
			FROM  divulgacao_escala.tb_vagas_operacao
			WHERE cod_vaga_operacao = ANY(v_arr_cod_vaga) AND NOT
			-- PERÍODO QUE NÃO PODE MARCAR GSV
			(
				(dat_ini_vagas > v_record.dat_ini_restricao_mesmo_local  AND dat_ini_vagas < v_record.dat_fim_restricao_mesmo_local) OR
				(dat_fim_vagas >  v_record.dat_ini_restricao_mesmo_local AND dat_fim_vagas < v_record.dat_fim_restricao_mesmo_local) OR
				(
					dat_ini_vagas < v_record.dat_ini_restricao_mesmo_local AND 
					dat_fim_vagas > v_record.dat_fim_restricao_mesmo_local 
				)
			);
		END IF;
	END LOOP; 
	
	-- RESTRIÇOES: VAGAS DE GSV SEQUENCIAIS E INTERVALO ANTES E APÓS MÁXIMO DE GSVs SEQUENCIAIS
	FOR v_record IN
	(
		SELECT 	
			dat_ini_vagas,
			dat_fim_vagas,
			LAG(dat_fim_vagas) OVER(ORDER BY dat_fim_vagas) AS dat_fim_vagas_anterior,
			LAG(dat_ini_vagas, -1) OVER(ORDER BY dat_fim_vagas) AS dat_ini_vagas_prox
		FROM divulgacao_escala.tb_vagas_operacao
		WHERE
			cod_pessoa_servidor_fk = p_cod_pessoa AND 
			(
				dat_ini_vagas BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR 
				dat_fim_vagas BETWEEN v_dat_ini_vagas AND v_dat_fim_vagas OR
				(
					dat_ini_vagas < v_dat_ini_vagas AND
					dat_fim_vagas > v_dat_fim_vagas
				)
			)
		ORDER BY dat_fim_vagas
	)
	LOOP
		--RAISE NOTICE 'fn_filtra_vagas_disponiveis - v_record: %', v_record;
		IF 	v_record.dat_fim_vagas_anterior IS NOT NULL AND 
			v_record.dat_ini_vagas = v_record.dat_fim_vagas_anterior 
		THEN 
			v_dat_fim_vaga_sequencial := v_record.dat_fim_vagas;
			v_qtd_gsv_sequencial := v_qtd_gsv_sequencial + 1;	
		ELSE
			v_dat_ini_vaga_sequencial := v_record.dat_ini_vagas;
			v_dat_fim_vaga_sequencial := v_record.dat_fim_vagas;
			v_qtd_gsv_sequencial := 1;
		END IF;
		
		IF 	v_record.dat_ini_vagas_prox IS NULL OR
			v_record.dat_fim_vagas != v_record.dat_ini_vagas_prox 
		THEN 
			IF 	v_qtd_gsv_sequencial > 1 AND 
				v_qtd_gsv_sequencial >= v_quantidade_gsv_sequencial_permitida 
			THEN				
				v_dat_ini_vaga_sequencial := v_dat_ini_vaga_sequencial - v_intervalo_hora_max_gsv_sequencial_permitida;
				v_dat_fim_vaga_sequencial := v_dat_fim_vaga_sequencial + v_intervalo_hora_max_gsv_sequencial_permitida;
								
				SELECT ARRAY_AGG(cod_vaga_operacao)
				INTO v_arr_cod_vaga
				FROM  divulgacao_escala.tb_vagas_operacao
				WHERE cod_vaga_operacao = ANY(v_arr_cod_vaga)AND NOT
				-- PERÍODO COM MÁXIMO DE GSVS SEQUENCIAIS PERMITIDO
				(
					(dat_ini_vagas > v_dat_ini_vaga_sequencial AND dat_ini_vagas < v_dat_fim_vaga_sequencial) OR
					(dat_fim_vagas > v_dat_ini_vaga_sequencial AND dat_fim_vagas < v_dat_fim_vaga_sequencial) OR
					(
						dat_ini_vagas < v_dat_ini_vaga_sequencial AND
						dat_fim_vagas > v_dat_fim_vaga_sequencial
					)
				);
			END IF;
		END IF;
		-- DEBUG DAS VAGAS SEQUENCIAIS
		--RAISE NOTICE 'fn_filtra_vagas_disponiveis - 	v_record.dat_ini_vagas: %',  v_record.dat_ini_vagas;
		--RAISE NOTICE 'fn_filtra_vagas_disponiveis - 	v_record.dat_fim_vagas: %',  v_record.dat_fim_vagas;
		--RAISE NOTICE 'fn_filtra_vagas_disponiveis - 	v_record.dat_fim_vagas_anterior: %',  v_record.dat_fim_vagas_anterior;		
		--RAISE NOTICE 'fn_filtra_vagas_disponiveis - 	v_dat_ini_vaga_sequencial: %', v_dat_ini_vaga_sequencial;		
		--RAISE NOTICE 'fn_filtra_vagas_disponiveis - 	v_dat_fim_vaga_sequencial: %', v_dat_fim_vaga_sequencial;		
		--RAISE NOTICE 'fn_filtra_vagas_disponiveis - 	v_qtd_gsv_sequencial: %',  v_qtd_gsv_sequencial;
	END LOOP;
	
	IF (array_length(v_arr_cod_vaga,1)IS NOT NULL) THEN
		RETURN v_arr_cod_vaga;
	ELSE 
		RETURN '{}'::integer[];
	END IF;
END;
$BODY$;

ALTER FUNCTION divulgacao_escala.fn_filtra_vagas_disponiveis(integer[], integer)
    OWNER TO postgres;

GRANT EXECUTE ON FUNCTION divulgacao_escala.fn_filtra_vagas_disponiveis(integer[], integer) TO PUBLIC;

GRANT EXECUTE ON FUNCTION divulgacao_escala.fn_filtra_vagas_disponiveis(integer[], integer) TO postgres;

GRANT EXECUTE ON FUNCTION divulgacao_escala.fn_filtra_vagas_disponiveis(integer[], integer) TO user_1400040;

GRANT EXECUTE ON FUNCTION divulgacao_escala.fn_filtra_vagas_disponiveis(integer[], integer) TO user_1400122;

