
SELECT * FROM graphql_brado.fn_brado_lista_agenda_militar(
	p_cod_pessoa_servidor bigint,
	p_dat_ini_periodo timestamp without time zone,
	p_dat_fim_periodo timestamp without time zone)
    WHERE cod_tipo_evento = 1 OR 4


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