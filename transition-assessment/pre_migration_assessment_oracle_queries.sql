/*
	Run these as dba admin. Should have access to system wide db views. 
	Replace semarchy_repository with the actual Repository name
	Each query can be run separately or entire statement at once
*/
select 
	A.assessment_category,
	A.description,
	A.object_name,
	A.model_name,
	A.model_deployment,
	A.impact_on_saas_transition,
	A.additional_information
from
(
	-- Check Database Functions & Procedures declared in the xDM model
	
	select 
		'Database Functions & Procedures' as assessment_category,
		'Declared in xDM'as description,
		msf.name as object_name,
		mrm.name as model_name,
		case when mdl.uuid is null then 'Model not deployed' else 'Model deployed' end as model_deployment,
		case when mdl.uuid is null then 'Alert' else 'Blocker' end as impact_on_saas_transition,
		'' as additional_information
	from semarchy_repository.mta_sql_function msf
	inner join semarchy_repository.mta_root_model mrm 
	on mrm.uuid = msf.o_model 
	left outer join semarchy_repository.mta_model_branch mmb 
	on mmb.o_rootmodel = mrm.uuid 
	left outer join semarchy_repository.mta_model_edition mme 
	on mme.o_modelbranch = mmb.uuid 
	left outer join semarchy_repository.mta_data_location mdl 
	on mdl.r_deployedme = mme.uuid 
	
	UNION ALL 
	
	
	-- Check Stored Procedures & Function that are created in the data location schema
	
	SELECT
	    CASE
	        WHEN p.object_type = 'FUNCTION'  THEN 'Database Function'
	        WHEN p.object_type = 'PROCEDURE' THEN 'Stored Procedure'
	    END AS assessment_category,
	    'Present in the data location schema' AS description,
	    p.object_name AS object_name,
	    'Not specific to model' AS model_name,
	    '' AS model_deployment,
	    'Blocker' AS impact_on_saas_transition,
	    'SchemaName = ' || p.owner AS additional_information
	FROM DBA_PROCEDURES p
	WHERE p.object_type IN ('FUNCTION', 'PROCEDURE')
	  AND p.owner NOT IN (
	      -- Oracle default/system accounts
	      'SYS','SYSTEM','OUTLN','XS$NULL','DBSNMP', 'DBSFWUSER', 'SYSMAN',
	      'ORDDATA','ORDPLUGINS','ORDSYS','ORDCOMMON',
	      'MDSYS','CTXSYS','EXFSYS','DMSYS','WMSYS','OLAPSYS',
	      'XDB','ANONYMOUS','APEX_PUBLIC_USER','APEX_030200',
	      'APEX_040000','APEX_050000','FLOWS_FILES','FLOWS_030200',
	      'FLOWS_040000','FLOWS_050000','OWBSYS','OWBSYS_AUDIT',
	      'SPATIAL_CSW_ADMIN_USR','SPATIAL_WFS_ADMIN_USR',
	      'OJVMSYS','AUDSYS','GSMADMIN_INTERNAL','GSMCATUSER',
	      'GSMUSER','REMOTE_SCHEDULER_AGENT','DIP','LBACSYS',
	      'DVF','DVSYS','RDSADMIN','SYSBACKUP','SYSDG','SYSKM',
	      'ORACLE_OCM','APPQOSSYS','SI_INFORMTN_SCHEMA', 'SEMARCHY_REPOSITORY'
	  )
	  AND p.object_name NOT LIKE 'SEM_%'
	  
	UNION ALL 
	
	
	--Check for SQL Hooks used
	
	SELECT 
	  CAST('SQL Hooks' AS VARCHAR2(30))                                                     AS assessment_category,
	  CAST('Model Job with SQL Hook Parameter' AS VARCHAR2(4000))                           AS description,
	  CAST(mmj.name AS VARCHAR2(256))                                                       AS object_name,
	  CAST(mrm.name AS VARCHAR2(256))                                                       AS model_name,
	  CAST(CASE WHEN mdl.uuid IS NULL THEN 'Model not deployed' ELSE 'Model deployed' END AS VARCHAR2(30)) AS model_deployment,
	  CAST(CASE WHEN mdl.uuid IS NULL THEN 'Alert' ELSE 'Blocker' END AS VARCHAR2(10))     AS impact_on_saas_transition,
	  CAST('' AS VARCHAR2(4000))                                                            AS additional_information
	FROM SEMARCHY_REPOSITORY.mta_model_job mmj
	JOIN SEMARCHY_REPOSITORY.mta_model_job_param mmjp
	  ON mmj.uuid = mmjp.o_model_job 
	JOIN SEMARCHY_REPOSITORY.mta_root_model mrm 
	  ON mmj.o_model = mrm.uuid 
	LEFT JOIN SEMARCHY_REPOSITORY.mta_model_branch mmb 
	  ON mmb.o_rootmodel = mrm.uuid 
	LEFT JOIN SEMARCHY_REPOSITORY.mta_model_edition mme 
	  ON mme.o_modelbranch = mmb.uuid 
	LEFT JOIN SEMARCHY_REPOSITORY.mta_data_location mdl 
	  ON mdl.r_deployedme = mme.uuid 
	WHERE mmjp.name = 'PARAM_SQL_HOOKS'
	
	UNION ALL
	
	/* Enrichers using a FUNCTION or PROCEDURE referenced in their expression */
	SELECT
	  CAST('Enrichers' AS VARCHAR2(30))                                                     AS assessment_category,
	  CAST('Enricher using stored proc or function in the entity [' || me2.name || ']' AS VARCHAR2(4000)) AS description,
	  CAST(me.name AS VARCHAR2(256))                                                        AS object_name,
	  CAST(mrm.name AS VARCHAR2(256))                                                       AS model_name,
	  CAST(CASE WHEN mdl.uuid IS NULL THEN 'Model not deployed' ELSE 'Model deployed' END AS VARCHAR2(30)) AS model_deployment,
	  CAST(CASE WHEN mdl.uuid IS NULL THEN 'Alert' ELSE 'Blocker' END AS VARCHAR2(10))     AS impact_on_saas_transition,
	  CAST(
	       'enricher expression = ' ||
	       /* Force CLOB to VARCHAR2 safely (adjust length if needed) */
	       COALESCE(DBMS_LOB.SUBSTR(mee.expression, 4000), CAST(NULL AS VARCHAR2(1)))
	       AS VARCHAR2(4000)
	  )                                                                                     AS additional_information
	FROM DBA_PROCEDURES p
	JOIN SEMARCHY_REPOSITORY.MTA_ENR_EXPR     mee ON UPPER(mee.expression) LIKE '%' || UPPER(p.object_name) || '%'
	JOIN SEMARCHY_REPOSITORY.MTA_ENRICHER     me  ON me.uuid = mee.o_enricher
	JOIN SEMARCHY_REPOSITORY.MTA_ENTITY       me2 ON me2.uuid = me.o_entity
	JOIN SEMARCHY_REPOSITORY.MTA_ROOT_MODEL   mrm ON me2.o_model = mrm.uuid
	LEFT JOIN SEMARCHY_REPOSITORY.MTA_MODEL_BRANCH  mmb  ON mmb.o_rootmodel   = mrm.uuid
	LEFT JOIN SEMARCHY_REPOSITORY.MTA_MODEL_EDITION mme2 ON mme2.o_modelbranch = mmb.uuid
	LEFT JOIN SEMARCHY_REPOSITORY.MTA_DATA_LOCATION mdl  ON mdl.r_deployedme  = mme2.uuid
	WHERE p.object_type IN ('FUNCTION','PROCEDURE')
	  AND p.owner NOT IN (
	    'SYS','SYSTEM','OUTLN','DBSNMP','SYSMAN','MDSYS','CTXSYS','XDB','OLAPSYS',
	    'ORDSYS','WMSYS','APPQOSSYS','APEX_PUBLIC_USER','FLOWS_FILES','DVSYS','DVF',
	    'LBACSYS','AUDSYS','OJVMSYS','GSMADMIN_INTERNAL','RDSADMIN','SI_INFORMTN_SCHEMA',
	    'SEMARCHY_REPOSITORY'
	  )
	  AND p.object_name NOT LIKE 'SEM_%'
	  AND me.classname = 'SemQLEnricher'
	
	 
	 UNION ALL
	
	--Check if any Dashboard is using a data source external to the xDM database
	SELECT 
	   'Dashboards' AS assessment_category,
	   concat('External datasource used = ', A.ds_name) as description,
	    mdo.app_name AS object_name,
	    'Not specific to model' AS model_name,
	    '' as model_deployment,
	    'Complexity' as impact_on_saas_transition,
	    'JdbcHostName = ' || NVL(JSON_VALUE(A.pool_config, '$.url'),JSON_VALUE(A.pool_config, '$.primaryPoolConfig.url')) as additional_information
	
	FROM semarchy_repository.mta_dash_object mdo 
	inner join 
	(
	select pd2.name as ds_name, pd2.pool_config
	from semarchy_repository.pds_datasource pd2 
	where REGEXP_SUBSTR(REPLACE(NVL(JSON_VALUE(pd2.pool_config, '$.url'),JSON_VALUE(pd2.pool_config, '$.primaryPoolConfig.url')),'jdbc:oracle:thin:@',''),'([^:]+)', 1, 1, NULL, 1) not in
	(
	select 
		REGEXP_SUBSTR(REPLACE(NVL(JSON_VALUE(pd.pool_config, '$.url'),JSON_VALUE(pd.pool_config, '$.primaryPoolConfig.url')),'jdbc:oracle:thin:@',''),'([^:]+)', 1, 1, NULL, 1) as jdbc_host_name 
	from semarchy_repository.mta_data_location mdl 
	inner join semarchy_repository.pds_datasource pd 
	on mdl.datasource_name = pd.name 
	)
	) A
	on TRIM(REGEXP_SUBSTR(REGEXP_SUBSTR(DBMS_LOB.SUBSTR(mdo.content, 4000), '^[^\n]+', 1, 1),'^[^:]*:\s*(.*)$', 1, 1, NULL, 1)) = A.ds_name
	
	UNION ALL 
	
	--Check any Data Notification is using target type other than REST
	select
		'Data Notification' as assessment_category,
		'Data notification target type not REST' as description,
		mdn.name as object_name,
		mrm.name model_name,
		'Model deployed' as model_deployment,
	    'Blocker'  as impact_on_saas_transition,
		mdn.target_type as additional_information
	FROM semarchy_repository.mta_data_notif mdn
	inner join semarchy_repository.mta_data_location mdl 
	on mdn.o_datalocation = mdl.uuid 
	inner join semarchy_repository.mta_model_edition mme 
	on mdl.r_deployedme = mme.uuid 
	inner join semarchy_repository.mta_model_branch mmb  
	on mme.o_modelbranch = mmb.uuid 
	inner join semarchy_repository.mta_root_model mrm 
	on mmb.o_rootmodel = mrm.uuid 
	where mdn.target_type <> 'REST'
	
	
	UNION ALL 
	
	--Check any Job notification using File or JMS
	select
		'Job Notification' as assessment_category,
		'Job notification using File, JMS, Java notification server' as description,
		mjnp.name as object_name,
		mrm.name model_name,
		'Model deployed' as model_deployment,
		'Blocker' as impact_on_saas_transition,
		concat(upper(replace(mns.plugin_id, 'com.semarchy.notification.plugins.convergence.', '')), 'server used')  as additional_information
	FROM SEMARCHY_REPOSITORY.mta_job_notif_policy mjnp 
	inner join SEMARCHY_REPOSITORY.mta_notif_server mns 
	on mjnp.r_notifserver = mns.uuid 
	inner join SEMARCHY_REPOSITORY.mta_data_location mdl 
	on mjnp.o_datalocation = mdl.uuid 
	inner join SEMARCHY_REPOSITORY.mta_model_edition mme 
	on mdl.r_deployedme = mme.uuid 
	inner join SEMARCHY_REPOSITORY.mta_model_branch mmb  
	on mme.o_modelbranch = mmb.uuid 
	inner join SEMARCHY_REPOSITORY.mta_root_model mrm 
	on mmb.o_rootmodel = mrm.uuid 
	where mns.plugin_id  in ('com.semarchy.notification.plugins.convergence.file','com.semarchy.notification.plugins.convergence.jms','com.semarchy.notification.plugin.convergence.mail.jee')
	
	union all 
	
	--Check datasources not used for deployment to be reviewed
	select 
		'Datasource' as assessment_category,
		'Datasources not used for model deployment' as descripton,
		name as object_name,
		'Not applicable' as model_name,
		'' as model_deployment,
		'For Review' as impact_on_saas_transition,
		'' as additional_information
	from semarchy_repository.pds_datasource 
	where name not in 
	(select datasource_name from semarchy_repository.mta_data_location) 
	
	union all
	
	--Check if any Custom Plug-ins are defined
	select 
		'Custom Plug-in' as assessment_category,
		'' as descripton,
		name as object_name,
		'Not applicable' as model_name,
		'' as model_deployment,
		'Blocker' as impact_on_saas_transition,
		concat('Version', version) as additional_information
	from semarchy_repository.mta_plugin mp  
	
	union all
	
	--Check if Variable Value Provider is created
	select 
		'Variable Provider' as assessment_category,
		'' as descripton,
		name as object_name,
		'Not applicable' as model_name,
		'' as model_deployment,
		'Blocker' as impact_on_saas_transition,
		plugin_id  as additional_information
	from semarchy_repository.mta_var_val_provider  
	
	
	UNION ALL 
	
	--Check if custom sequences are created
	SELECT
	  'Custom Sequences'                                      AS assessment_category,
	  s.sequence_name                                         AS object_name,
	  'In schema = ' || s.sequence_owner                      AS description,
	  'Not applicable'                                        AS model_name,
	  ''                                                      AS model_deployment,
	  'Blocker'                                               AS impact_on_saas_transition,
	  ''                                                      AS additional_information
	FROM ALL_SEQUENCES s
	WHERE s.sequence_owner NOT IN (
	  /* exclude default/system owners */
	  'SYS','SYSTEM','OUTLN','XS$NULL','DBSNMP','SYSMAN',
	  'ORDDATA','ORDPLUGINS','ORDSYS','ORDCOMMON',
	  'MDSYS','CTXSYS','EXFSYS','DMSYS','WMSYS','OLAPSYS',
	  'XDB','ANONYMOUS','APEX_PUBLIC_USER','APEX_030200',
	  'APEX_040000','APEX_050000','FLOWS_FILES','FLOWS_030200',
	  'FLOWS_040000','FLOWS_050000','OWBSYS','OWBSYS_AUDIT',
	  'SPATIAL_CSW_ADMIN_USR','SPATIAL_WFS_ADMIN_USR',
	  'OJVMSYS','AUDSYS','GSMADMIN_INTERNAL','GSMCATUSER',
	  'GSMUSER','REMOTE_SCHEDULER_AGENT','DIP','LBACSYS',
	  'DVF','DVSYS','RDSADMIN','SYSBACKUP','SYSDG','SYSKM',
	  'ORACLE_OCM','APPQOSSYS','SI_INFORMTN_SCHEMA'
	)
	AND UPPER(s.sequence_name) NOT IN (
	  /* exclude known Semarchy/system sequences (uppercase for Oracle) */
	  'DL_SEQ_DUPS_OPERATION',
	  'DL_SEQ_FILTER',
	  'WF_SEQ_STEP_INST_ID',
	  'WF_SEQ_WORK_ITEM_ID',
	  'WF_SEQ_WORKFLOW_INST_ID',
	  'SEQ_BATCHID',
	  'SEQ_DATANOTIFLOGID',
	  'SEQ_LOADID',
	  'SEQ_REVISION',
	  'SEQ_MATCHGRP'
	)
	AND UPPER(s.sequence_name) NOT IN 
	  (
	  	select concat('seq_', lower(me.phys_tabname)) sequence_name
	  	from semarchy_repository.mta_attribute ma 
	  	inner join semarchy_repository.mta_entity me 
	  	on ma.o_entity = me.uuid 
	  	where case when me.entity_type = 'FUZZY_MATCHED' then ma.fuzz_gold_id_gen_type else ma.id_gen_type end = 'SEQUENCE'
	  	union 
	  	select concat('ssq_', lower(me.phys_tabname)) sequence_name
	  	from semarchy_repository.mta_attribute ma 
	  	inner join semarchy_repository.mta_entity me 
	  	on ma.o_entity = me.uuid 
	  	where case when me.entity_type = 'FUZZY_MATCHED' then ma.fuzz_gold_id_gen_type else ma.id_gen_type end = 'SEQUENCE'
	  )
	  
	  UNION ALL 
	  
	  -- Check views are created in the xdm data location or repository schema
	 SELECT
	  'Database Views'                                       AS assessment_category,
	  v.view_name                                            AS object_name,
	  'In schema = ' || v.owner                              AS description,
	  'Not applicable'                                       AS model_name,
	  ''                                                     AS model_deployment,
	  'Complexity'                                           AS impact_on_saas_transition,
	  ''                                                     AS additional_information
	FROM ALL_VIEWS v
	WHERE v.owner NOT IN (
	  /* Exclude Oracle default/system schemas */
	  'SYS','SYSTEM','OUTLN','XS$NULL','DBSNMP','SYSMAN',
	  'ORDDATA','ORDPLUGINS','ORDSYS','ORDCOMMON',
	  'MDSYS','CTXSYS','EXFSYS','DMSYS','WMSYS','OLAPSYS',
	  'XDB','ANONYMOUS','APEX_PUBLIC_USER','APEX_030200',
	  'APEX_040000','APEX_050000','FLOWS_FILES','FLOWS_030200',
	  'FLOWS_040000','FLOWS_050000','OWBSYS','OWBSYS_AUDIT',
	  'SPATIAL_CSW_ADMIN_USR','SPATIAL_WFS_ADMIN_USR',
	  'OJVMSYS','AUDSYS','GSMADMIN_INTERNAL','GSMCATUSER',
	  'GSMUSER','REMOTE_SCHEDULER_AGENT','DIP','LBACSYS',
	  'DVF','DVSYS','RDSADMIN','SYSBACKUP','SYSDG','SYSKM',
	  'ORACLE_OCM','APPQOSSYS','SI_INFORMTN_SCHEMA'
	)
	
	UNION ALL 
	 
	 --Check if custom indexes are created
	SELECT
	  CAST('Custom Indexes' AS VARCHAR2(30))                                                       AS assessment_category,
	  CAST('In schema = ' || ai.owner || ' & table = ' || ai.table_name AS VARCHAR2(4000))         AS description,
	  CAST(ai.index_name AS VARCHAR2(128))                                                         AS object_name,
	  CAST('Not applicable' AS VARCHAR2(256))                                                      AS model_name,
	  CAST('' AS VARCHAR2(30))                                                                     AS model_deployment,
	  CAST('To be reviewed' AS VARCHAR2(20))                                                       AS impact_on_saas_transition,
	  /* Index DDL as text (avoid CLOB by trimming to 4000 chars) */
	  CAST(DBMS_LOB.SUBSTR(DBMS_METADATA.GET_DDL('INDEX', ai.index_name, ai.owner), 4000)
	       AS VARCHAR2(4000))                                                                      AS additional_information
	FROM DBA_INDEXES ai
	WHERE
	  /* Exclude Oracle default/system schemas */
	  ai.owner NOT IN (
	    'SYS','SYSTEM','OUTLN','XS$NULL','DBSNMP','SYSMAN',
	    'ORDDATA','ORDPLUGINS','ORDSYS','ORDCOMMON',
	    'MDSYS','CTXSYS','EXFSYS','DMSYS','WMSYS','OLAPSYS',
	    'XDB','ANONYMOUS','APEX_PUBLIC_USER','APEX_030200',
	    'APEX_040000','APEX_050000','FLOWS_FILES','FLOWS_030200',
	    'FLOWS_040000','FLOWS_050000','OWBSYS','OWBSYS_AUDIT',
	    'SPATIAL_CSW_ADMIN_USR','SPATIAL_WFS_ADMIN_USR',
	    'OJVMSYS','AUDSYS','GSMADMIN_INTERNAL','GSMCATUSER',
	    'GSMUSER','REMOTE_SCHEDULER_AGENT','DIP','LBACSYS',
	    'DVF','DVSYS','RDSADMIN','SYSBACKUP','SYSDG','SYSKM',
	    'ORACLE_OCM','APPQOSSYS','SI_INFORMTN_SCHEMA', 'DBSFWUSER'
	  )
	  /* Exclude schemas that contain the Semarchy repository table MTA_REPOSITORY */
	  AND ai.owner NOT IN (SELECT owner FROM ALL_TABLES WHERE table_name = 'MTA_REPOSITORY')
	  /* Exclude known Semarchy/system index name prefixes (use 2-char prefix like PG’s SUBSTRING(…,1,2)) */
	  AND UPPER(SUBSTR(ai.index_name, 3, 2)) NOT IN
	      ('AE','GD','GX','SA','GH','DL','WF','DU','GA','GE','GF','GI','GP','MD','MH','MI','MX','SD','SE','SF','UM','XG','EX')
	  AND UPPER(SUBSTR(ai.index_name, 1, 2)) NOT IN
	      ('PK','FK','IX','I1','I2','I3','I4','I5','I6','I7','I8','I9')
	  /* Exclude specific table like in the PG query */
	  AND ai.table_name <> 'EXT_EMAIL_DOMAINS'
  
) A order by 1;

