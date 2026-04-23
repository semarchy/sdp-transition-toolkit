/*
	DBA admin should preferebaly run this query or someone with access to both SEMARCHY_REPOSITORY and the required Data Location DBs. 
	Replace SEMARCHY_REPOSITORY with actual repository name. 
	Replace SEMARCHY_DLOC1 with actual data lcoation name for which you wish to run this report. 
	
	Each statement can be run separately except for below two that require the very first CTE expression (dloc_routines) - 
		3) Enrichers using a function or stored procedure in the xDM model 
		AND 
		4) Validators using a function or stored procedure in the xDM model
	in which case, you can use the CTE (dloc_routines) and run them with the SELECT statements of - 
		3) Enrichers using a function or stored procedure in the xDM model 
		AND 
		4) Validators using a function or stored procedure in the xDM model
		
*/

-- CTE required by Enrichers and Validators using function or stored proc in xDM model sql statements
WITH dloc_routines AS (
    SELECT 
        s.name AS schema_name,
        o.name AS object_name,
        o.type AS object_type
    FROM SEMARCHY_DLOC1.sys.objects AS o
    JOIN SEMARCHY_DLOC1.sys.schemas AS s 
      ON s.schema_id = o.schema_id
    WHERE o.type IN ('P','FN','IF','TF','FS','FT','PC','X')  -- procs & functions (incl. CLR/X)
      AND o.name NOT LIKE 'sem_%'
)
-- Report beginning 
SELECT  
    A.assessment_category,
    A.description,
    A.object_name,
    A.model_name,
    A.model_deployment,
    A.impact_on_saas_transition,
    A.additional_information
FROM (

	/* --Check for SQL Hooks used */
	SELECT 
	    'SQL Hooks' AS assessment_category,
	    'Model Job with SQL Hook Parameter' AS description,
	    mmj.[name] AS object_name,
	    mrm.[name] AS model_name,
	    CASE 
	        WHEN mdl.uuid IS NULL THEN 'Model not deployed'
	        ELSE 'Model deployed'
	    END AS model_deployment,
	    CASE 
	        WHEN mdl.uuid IS NULL THEN 'Alert'
	        ELSE 'Blocker'
	    END AS impact_on_saas_transition,
	    '' AS additional_information
	FROM SEMARCHY_REPOSITORY.dbo.mta_model_job AS mmj
	INNER JOIN SEMARCHY_REPOSITORY.dbo.mta_model_job_param AS mmjp
	    ON mmj.uuid = mmjp.o_model_job
	INNER JOIN SEMARCHY_REPOSITORY.dbo.mta_root_model AS mrm
	    ON mmj.o_model = mrm.uuid
	LEFT JOIN SEMARCHY_REPOSITORY.dbo.mta_model_branch AS mmb
	    ON mmb.o_rootmodel = mrm.uuid
	LEFT JOIN SEMARCHY_REPOSITORY.dbo.mta_model_edition AS mme
	    ON mme.o_modelbranch = mmb.uuid AND mme.status = 'OPEN'
	LEFT JOIN SEMARCHY_REPOSITORY.dbo.mta_data_location AS mdl
	    ON mdl.r_deployedme = mme.uuid
	WHERE mmjp.[name] = 'PARAM_SQL_HOOKS'
	
	UNION ALL 
	
	
    /* 1) Database Functions & Procedures declared in the xDM model */
    SELECT 
        'Database Functions & Procedures' AS assessment_category,
        'Declared in xDM'                 AS description,
        msf.[name]                        AS object_name,
        mrm.[name]                        AS model_name,
        CASE WHEN mdl.uuid IS NULL THEN 'Model not deployed' ELSE 'Model deployed' END AS model_deployment,
        CASE WHEN mdl.uuid IS NULL THEN 'Alert'               ELSE 'Blocker'        END AS impact_on_saas_transition,
        ''                                 AS additional_information
    FROM SEMARCHY_REPOSITORY.dbo.mta_sql_function AS msf
    INNER JOIN SEMARCHY_REPOSITORY.dbo.mta_root_model AS mrm 
        ON mrm.uuid = msf.o_model
    LEFT JOIN SEMARCHY_REPOSITORY.dbo.mta_model_branch AS mmb 
        ON mmb.o_rootmodel = mrm.uuid
    LEFT JOIN SEMARCHY_REPOSITORY.dbo.mta_model_edition AS mme 
        ON mme.o_modelbranch = mmb.uuid
    LEFT JOIN SEMARCHY_REPOSITORY.dbo.mta_data_location AS mdl 
        ON mdl.r_deployedme = mme.uuid

    UNION ALL

    /* 2) Procs/Functions present in the data location schema */
    SELECT 
        CASE 
            WHEN o.type IN ('P','PC','X')             THEN 'Stored Procedure'
            WHEN o.type IN ('FN','IF','TF','FS','FT') THEN 'Database Function'
        END                              AS assessment_category,
        'Present in the data location schema' AS description,
        o.name                           AS object_name,
        'Not specific to model'          AS model_name,
        CAST('' AS nvarchar(1))          AS model_deployment,
        'Blocker'                        AS impact_on_saas_transition,
        CONCAT('SchemaName = ', s.name)  AS additional_information
    FROM SEMARCHY_DLOC1.sys.objects AS o
    JOIN SEMARCHY_DLOC1.sys.schemas AS s
      ON s.schema_id = o.schema_id
    WHERE o.type IN ('P','PC','X','FN','IF','TF','FS','FT')
      AND s.name NOT IN (N'sys')
      AND o.name NOT LIKE N'sem[_]%'

    UNION ALL

	-- Use the CTE expression at the top with this SELECT if you want to run it independently 
    /* 3) Enrichers using a function or stored procedure in the xDM model */
    SELECT DISTINCT
        'Enrichers' AS assessment_category,
        CONCAT('Enricher using stored proc or function in the entity [', me2.[name], ']') AS description,
        me.[name]                         AS object_name,
        mrm.[name]                        AS model_name,
        CASE 
          WHEN EXISTS (
            SELECT 1
            FROM SEMARCHY_REPOSITORY.dbo.mta_model_branch  AS mmb
            JOIN SEMARCHY_REPOSITORY.dbo.mta_model_edition AS mme ON mme.o_modelbranch = mmb.uuid
            JOIN SEMARCHY_REPOSITORY.dbo.mta_data_location AS mdl ON mdl.r_deployedme   = mme.uuid
            WHERE mmb.o_rootmodel = mrm.uuid
          )
          THEN 'Model deployed' ELSE 'Model not deployed'
        END AS model_deployment,
        CASE 
          WHEN EXISTS (
            SELECT 1
            FROM SEMARCHY_REPOSITORY.dbo.mta_model_branch  AS mmb
            JOIN SEMARCHY_REPOSITORY.dbo.mta_model_edition AS mme ON mme.o_modelbranch = mmb.uuid
            JOIN SEMARCHY_REPOSITORY.dbo.mta_data_location AS mdl ON mdl.r_deployedme   = mme.uuid
            WHERE mmb.o_rootmodel = mrm.uuid
          )
          THEN 'Blocker' ELSE 'Alert'
        END AS impact_on_saas_transition,
        CONCAT('enricher expression = ', mee.[expression]) AS additional_information
    FROM SEMARCHY_REPOSITORY.dbo.mta_enr_expr   AS mee
    JOIN SEMARCHY_REPOSITORY.dbo.mta_enricher   AS me   ON me.uuid   = mee.o_enricher
    JOIN SEMARCHY_REPOSITORY.dbo.mta_entity     AS me2  ON me2.uuid  = me.o_entity
    JOIN SEMARCHY_REPOSITORY.dbo.mta_root_model AS mrm  ON me2.o_model = mrm.uuid
    WHERE me.classname = 'SemQLEnricher'
      AND EXISTS (
          SELECT 1
          FROM dloc_routines AS dr
          CROSS APPLY (
            SELECT
              '%' + QUOTENAME(dr.schema_name) + '.' + QUOTENAME(dr.object_name) + '%' AS p_bracketed,
              '%' + dr.schema_name + '.' + dr.object_name + '%'                       AS p_schema_dot,
              '% ' + dr.schema_name + '.' + dr.object_name + '(%'                     AS p_fn_qualified,
              '% ' + dr.object_name + '(%'                                            AS p_fn_unqualified,
              '% EXEC ' + dr.schema_name + '.' + dr.object_name + '%'                 AS p_exec_qualified,
              '% EXEC ' + dr.object_name + '%'                                        AS p_exec_unqualified
          ) AS pat
          WHERE
               mee.[expression] COLLATE Latin1_General_100_CI_AS LIKE pat.p_bracketed
            OR mee.[expression] COLLATE Latin1_General_100_CI_AS LIKE pat.p_schema_dot
            OR mee.[expression] COLLATE Latin1_General_100_CI_AS LIKE pat.p_fn_qualified
            OR mee.[expression] COLLATE Latin1_General_100_CI_AS LIKE pat.p_fn_unqualified
            OR mee.[expression] COLLATE Latin1_General_100_CI_AS LIKE pat.p_exec_qualified
            OR mee.[expression] COLLATE Latin1_General_100_CI_AS LIKE pat.p_exec_unqualified
      )

    UNION ALL
	
	-- Use the CTE expression at the top with this SELECT if you want to run it independently 
    /* 4) Validators using a function or stored procedure in the xDM model */
    SELECT DISTINCT
        'Validators' AS assessment_category,  
        CONCAT('Validator using stored proc or function in the entity [', me2.[name], ']') AS description,
        mc.[name]                         AS object_name,
        mrm.[name]                        AS model_name,
        CASE 
          WHEN EXISTS (
            SELECT 1
            FROM SEMARCHY_REPOSITORY.dbo.mta_model_branch  AS mmb
            JOIN SEMARCHY_REPOSITORY.dbo.mta_model_edition AS mme ON mme.o_modelbranch = mmb.uuid
            JOIN SEMARCHY_REPOSITORY.dbo.mta_data_location AS mdl ON mdl.r_deployedme   = mme.uuid
            WHERE mmb.o_rootmodel = mrm.uuid
          )
          THEN 'Model deployed' ELSE 'Model not deployed'
        END AS model_deployment,
        CASE 
          WHEN EXISTS (
            SELECT 1
            FROM SEMARCHY_REPOSITORY.dbo.mta_model_branch  AS mmb
            JOIN SEMARCHY_REPOSITORY.dbo.mta_model_edition AS mme ON mme.o_modelbranch = mmb.uuid
            JOIN SEMARCHY_REPOSITORY.dbo.mta_data_location AS mdl ON mdl.r_deployedme   = mme.uuid
            WHERE mmb.o_rootmodel = mrm.uuid
          )
          THEN 'Blocker' ELSE 'Alert'
        END AS impact_on_saas_transition,
        CONCAT('validator_condition = ', mc.[condition]) AS additional_information
    FROM SEMARCHY_REPOSITORY.dbo.mta_checkcons  AS mc   
    JOIN SEMARCHY_REPOSITORY.dbo.mta_entity     AS me2  ON me2.uuid  = mc.o_entity
    JOIN SEMARCHY_REPOSITORY.dbo.mta_root_model AS mrm  ON me2.o_model = mrm.uuid
    WHERE mc.classname = 'CheckConstraint'
      AND EXISTS (
          SELECT 1
          FROM dloc_routines AS dr
          CROSS APPLY (
            SELECT
              '%' + QUOTENAME(dr.schema_name) + '.' + QUOTENAME(dr.object_name) + '%' AS p_bracketed,
              '%' + dr.schema_name + '.' + dr.object_name + '%'                       AS p_schema_dot,
              '% ' + dr.schema_name + '.' + dr.object_name + '(%'                     AS p_fn_qualified,
              '% ' + dr.object_name + '(%'                                            AS p_fn_unqualified,
              '% EXEC ' + dr.schema_name + '.' + dr.object_name + '%'                 AS p_exec_qualified,
              '% EXEC ' + dr.object_name + '%'                                        AS p_exec_unqualified
          ) AS pat
          WHERE
               mc.[condition] COLLATE Latin1_General_100_CI_AS LIKE pat.p_bracketed
            OR mc.[condition] COLLATE Latin1_General_100_CI_AS LIKE pat.p_schema_dot
            OR mc.[condition] COLLATE Latin1_General_100_CI_AS LIKE pat.p_fn_qualified
            OR mc.[condition] COLLATE Latin1_General_100_CI_AS LIKE pat.p_fn_unqualified
            OR mc.[condition] COLLATE Latin1_General_100_CI_AS LIKE pat.p_exec_qualified
            OR mc.[condition] COLLATE Latin1_General_100_CI_AS LIKE pat.p_exec_unqualified
      )

    UNION ALL

    /* 5) Dashboards using external datasource */
    SELECT 
       'Dashboards' AS assessment_category,
       CONCAT('External datasource used = ', A.ds_name) AS description,
       mdo.app_name AS object_name,
       'Not specific to model' AS model_name,
       '' AS model_deployment,
       'Complexity' AS impact_on_saas_transition,
       CONCAT('JdbcHostName = ', COALESCE(JSON_VALUE(A.pool_config, '$.url'),
                                          JSON_VALUE(A.pool_config, '$.primaryPoolConfig.url'))) AS additional_information
    FROM SEMARCHY_REPOSITORY.dbo.mta_dash_object mdo 
    INNER JOIN (
        SELECT
          pd2.[name] AS ds_name,
          pd2.pool_config
        FROM semarchy_repository.dbo.pds_datasource AS pd2
        CROSS APPLY (
          SELECT COALESCE(
                   JSON_VALUE(pd2.pool_config, '$.url'),
                   JSON_VALUE(pd2.pool_config, '$.primaryPoolConfig.url')
                 ) AS jdbc_url
        ) AS j
        CROSS APPLY (
          SELECT CASE WHEN j.jdbc_url IS NULL THEN NULL
                      ELSE REPLACE(j.jdbc_url, 'jdbc:sqlserver://', '')
                 END AS url_no_prefix
        ) AS p
        CROSS APPLY (
          SELECT LEFT(
                   p.url_no_prefix,
                   ISNULL(NULLIF(CHARINDEX(':', p.url_no_prefix), 0) - 1, LEN(p.url_no_prefix))
                 ) AS jdbc_host_name
        ) AS u
        WHERE u.jdbc_host_name NOT IN (
            SELECT
              LEFT(u2.url_no_prefix,
                   ISNULL(NULLIF(CHARINDEX(':', u2.url_no_prefix), 0) - 1, LEN(u2.url_no_prefix))
              )
            FROM semarchy_repository.dbo.mta_data_location AS mdl
            JOIN semarchy_repository.dbo.pds_datasource    AS pd
              ON mdl.datasource_name = pd.[name]
            CROSS APPLY (
              SELECT COALESCE(
                       JSON_VALUE(pd.pool_config, '$.url'),
                       JSON_VALUE(pd.pool_config, '$.primaryPoolConfig.url')
                     ) AS jdbc_url
            ) AS j2
            CROSS APPLY (
              SELECT REPLACE(j2.jdbc_url, 'jdbc:sqlserver://', '') AS url_no_prefix
            ) AS u2
        )
    ) A
      ON LTRIM(RTRIM(
           CASE
             WHEN CHARINDEX(':',
                  CASE WHEN CHARINDEX(CHAR(10), mdo.[content]) > 0
                       THEN LEFT(mdo.[content], CHARINDEX(CHAR(10), mdo.[content]) - 1)
                       ELSE mdo.[content]
                  END) > 0
             THEN SUBSTRING(
                    CASE WHEN CHARINDEX(CHAR(10), mdo.[content]) > 0
                         THEN LEFT(mdo.[content], CHARINDEX(CHAR(10), mdo.[content]) - 1)
                         ELSE mdo.[content]
                    END,
                    CHARINDEX(':',
                      CASE WHEN CHARINDEX(CHAR(10), mdo.[content]) > 0
                           THEN LEFT(mdo.[content], CHARINDEX(CHAR(10), mdo.[content]) - 1)
                           ELSE mdo.[content]
                      END
                    ) + 1,
                    LEN(mdo.[content])
                  )
             ELSE ''
           END
         )) = A.ds_name

    UNION ALL

    /* 6) Data Notifications not REST */
    SELECT
        'Data Notification' AS assessment_category,
        'Data notification target type not REST' AS description,
        mdn.[name] AS object_name,
        mrm.[name] AS model_name,
        'Model deployed' AS model_deployment,
        'Blocker' AS impact_on_saas_transition,
        mdn.target_type AS additional_information
    FROM semarchy_repository.dbo.mta_data_notif mdn
    INNER JOIN semarchy_repository.dbo.mta_data_location mdl 
      ON mdn.o_datalocation = mdl.uuid 
    INNER JOIN semarchy_repository.dbo.mta_model_edition mme 
      ON mdl.r_deployedme = mme.uuid 
    INNER JOIN semarchy_repository.dbo.mta_model_branch mmb  
      ON mme.o_modelbranch = mmb.uuid 
    INNER JOIN semarchy_repository.dbo.mta_root_model mrm 
      ON mmb.o_rootmodel = mrm.uuid 
    WHERE mdn.target_type <> 'REST'

    UNION ALL

    /* 7) Job notifications using File/JMS/JEE mail */
    SELECT
        'Job Notification' AS assessment_category,
        'Job notification using File, JMS, Java notification server' AS description,
        mjnp.[name] AS object_name,
        mrm.[name] AS model_name,
        'Model deployed' AS model_deployment,
        'Blocker' AS impact_on_saas_transition,
        CONCAT(
            UPPER(REPLACE(mns.plugin_id, 'com.semarchy.notification.plugins.convergence.', '')),
            'server used'
        ) AS additional_information
    FROM semarchy_repository.dbo.mta_job_notif_policy mjnp
    INNER JOIN semarchy_repository.dbo.mta_notif_server mns 
      ON mjnp.r_notifserver = mns.uuid 
    INNER JOIN semarchy_repository.dbo.mta_data_location mdl 
      ON mjnp.o_datalocation = mdl.uuid 
    INNER JOIN semarchy_repository.dbo.mta_model_edition mme 
      ON mdl.r_deployedme = mme.uuid 
    INNER JOIN semarchy_repository.dbo.mta_model_branch mmb  
      ON mme.o_modelbranch = mmb.uuid 
    INNER JOIN semarchy_repository.dbo.mta_root_model mrm 
      ON mmb.o_rootmodel = mrm.uuid 
    WHERE mns.plugin_id IN (
        'com.semarchy.notification.plugins.convergence.file',
        'com.semarchy.notification.plugins.convergence.jms',
        'com.semarchy.notification.plugin.convergence.mail.jee'
    )

    UNION ALL

    /* 8) Datasources not used for deployment */
    SELECT 
        'Datasource' AS assessment_category,
        'Datasources not used for model deployment' AS description,
        [name] AS object_name,
        'Not applicable' AS model_name,
        '' AS model_deployment,
        'For Review' AS impact_on_saas_transition,
        '' AS additional_information
    FROM semarchy_repository.dbo.pds_datasource 
    WHERE [name] NOT IN (
        SELECT datasource_name FROM semarchy_repository.dbo.mta_data_location
    )

    UNION ALL

    /* 9) Custom Plug-ins defined */
    SELECT 
        'Custom Plug-in' AS assessment_category,
        '' AS description,
        [name] AS object_name,
        'Not applicable' AS model_name,
        '' AS model_deployment,
        'Blocker' AS impact_on_saas_transition,
        CONCAT('Version', [version]) AS additional_information
    FROM semarchy_repository.dbo.mta_plugin

    UNION ALL

    /* 10) Variable Value Provider created */
	SELECT 
	    CAST('Variable Provider' AS NVARCHAR(4000)) COLLATE DATABASE_DEFAULT AS assessment_category,
	    CAST('' AS NVARCHAR(4000)) COLLATE DATABASE_DEFAULT AS descripton,
	    CAST([name] AS NVARCHAR(4000)) COLLATE DATABASE_DEFAULT AS object_name,
	    CAST('Not applicable' AS NVARCHAR(4000)) COLLATE DATABASE_DEFAULT AS model_name,
	    CAST('' AS NVARCHAR(4000)) COLLATE DATABASE_DEFAULT AS model_deployment,
	    CAST('Blocker' AS NVARCHAR(4000)) COLLATE DATABASE_DEFAULT AS impact_on_saas_transition,
	    CAST(plugin_id AS NVARCHAR(4000)) COLLATE DATABASE_DEFAULT AS additional_information
	FROM SEMARCHY_REPOSITORY.dbo.mta_var_val_provider

    UNION ALL

    /* 11) Custom sequences (SQL Server) */
    SELECT
        'Custom Sequences'               AS assessment_category,
        CONCAT('In schema = ', sch.name) AS description,
        s.name                           AS object_name,
        'Not applicable'                 AS model_name,
        ''                               AS model_deployment,
        'Blocker'                        AS impact_on_saas_transition,
        ''                               AS additional_information
    FROM SEMARCHY_DLOC1.sys.sequences AS s
    JOIN SEMARCHY_DLOC1.sys.schemas AS sch 
      ON sch.schema_id = s.schema_id
    JOIN SEMARCHY_DLOC1.sys.objects AS o 
      ON o.object_id = s.object_id
    WHERE o.is_ms_shipped = 0
      AND sch.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'dbo')
      AND s.name NOT IN (
        'dl_seq_dups_operation','dl_seq_filter','wf_seq_step_inst_id','wf_seq_work_item_id',
        'wf_seq_workflow_inst_id','seq_batchid','seq_datanotiflogid','seq_loadid',
        'seq_revision','seq_matchgrp'
      )
      AND s.name NOT IN (
        SELECT CONCAT('seq_', LOWER(me.phys_tabname))
        FROM semarchy_repository.dbo.mta_attribute AS ma
        INNER JOIN semarchy_repository.dbo.mta_entity AS me 
          ON ma.o_entity = me.uuid
        WHERE CASE WHEN me.entity_type = 'FUZZY_MATCHED' THEN ma.fuzz_gold_id_gen_type ELSE ma.id_gen_type END = 'SEQUENCE'
        UNION
        SELECT CONCAT('ssq_', LOWER(me.phys_tabname))
        FROM semarchy_repository.dbo.mta_attribute AS ma
        INNER JOIN semarchy_repository.dbo.mta_entity AS me 
          ON ma.o_entity = me.uuid
        WHERE CASE WHEN me.entity_type = 'FUZZY_MATCHED' THEN ma.fuzz_gold_id_gen_type ELSE ma.id_gen_type END = 'SEQUENCE'
      )

    UNION ALL

    /* 12) Database Views in DLOC (SQL Server) */
    SELECT
        'Database Views'                       AS assessment_category,
        CONCAT('In schema = ', s.name)         AS description,
        v.name                                 AS object_name,
        'Not applicable'                       AS model_name,
        ''                                     AS model_deployment,
        'Complexity'                           AS impact_on_saas_transition,
        ''                                     AS additional_information
    FROM SEMARCHY_DLOC1.sys.views AS v
    JOIN SEMARCHY_DLOC1.sys.schemas AS s
      ON v.schema_id = s.schema_id
    WHERE s.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'dbo')

    UNION ALL

    /* 13) Custom Indexes (SQL Server) */
    SELECT
        'Custom Indexes' AS assessment_category,
        CONCAT('In schema = ', s.name, ' & table = ', t.name) AS description,
        i.name AS object_name,
        'Not applicable' AS model_name,
        '' AS model_deployment,
        'To be reviewed' AS impact_on_saas_transition,
        i.type_desc AS additional_information
    FROM sys.indexes AS i
    JOIN sys.tables AS t  ON i.object_id = t.object_id
    JOIN sys.schemas AS s ON t.schema_id = s.schema_id
    WHERE s.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'dbo')
      AND t.name <> 'mta_repository'
      AND i.name IS NOT NULL
      AND SUBSTRING(i.name, 3, 2) NOT IN ('ae','gd','gx','sa','gh','dl','wf','du','ga','ge','gf','gi','gp','md','mh','mi','mx','sd','se','sf','um','xg','ex')
      AND SUBSTRING(i.name, 1, 2) NOT IN ('pk','fk','ix','i1','i2','i3','i4','i5','i6','i7','i8','i9','i10','i11')
      AND t.name NOT IN ('ext_email_domains')
) AS A
ORDER BY 1;