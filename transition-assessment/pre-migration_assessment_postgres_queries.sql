--BEFORE EXECUTING!!
--SET YOUR SEMARCHY REPOSITORY BELOW

SET search_path TO semarchy_repository;

--BEGIN QUERY
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
	msf."name" as object_name,
	mrm.name as model_name,
	case when mdl.uuid is null then 'Model not deployed' else 'Model deployed' end as model_deployment,
	case when mdl.uuid is null then 'Alert' else 'Blocker' end as impact_on_saas_transition,
	'' as additional_information
from mta_sql_function msf
inner join mta_root_model mrm 
on mrm.uuid = msf.o_model 
left outer join mta_model_branch mmb 
on mmb.o_rootmodel = mrm.uuid 
left outer join mta_model_edition mme 
on mme.o_modelbranch = mmb.uuid 
left outer join mta_data_location mdl 
on mdl.r_deployedme = mme.uuid 

union all 

-- Check Stored Procedures & Function that are created in the data location schema
SELECT 
    CASE p.prokind
        WHEN 'f' THEN 'Databse Function'
        WHEN 'p' THEN 'Stored Procedure'
    END AS assessment_category,
    'Present in the data location schema' as description,
    p.proname AS object_name,
    'Not specific to model' AS model_name,
    '' as model_deployment,
    'Blocker' as impact_on_saas_transition,
    concat('SchemaName = ',n.nspname) as additional_information
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
JOIN pg_catalog.pg_roles r ON r.oid = p.proowner
WHERE n.nspname not in  ('pg_catalog', 'public', 'extensions', 'information_schema', 'semarchy_repository')
and p.proname not like 'sem_%'

union all 

--Check for SQL Hooks used
SELECT 
	'SQL Hooks' as assessment_category,
	'Model Job with SQL Hook Parameter' as description,
	mmj.name as object_name,
	mrm.name as model_name,
	case when mdl.uuid is null then 'Model not deployed' else 'Model deployed' end as model_deployment,
	case when mdl.uuid is null then 'Alert' else 'Blocker' end as impact_on_saas_transition,
	'' as additional_information
FROM mta_model_job mmj
inner join mta_model_job_param mmjp
on mmj.uuid = mmjp.o_model_job 
inner join mta_root_model mrm 
on mmj.o_model = mrm.uuid 
left outer join mta_model_branch mmb 
on mmb.o_rootmodel = mrm.uuid 
left outer join mta_model_edition mme 
on mme.o_modelbranch = mmb.uuid 
left outer join mta_data_location mdl 
on mdl.r_deployedme = mme.uuid 
where mmjp."name" = 'PARAM_SQL_HOOKS'

union all 

--Check any enricher is using a function or a stored procedure in the xDM model
SELECT 
  'Enrichers' as assessment_category,
  concat('Enricher using stored proc or function in the entity [', me2."name", ']') as description,
  me."name" object_name,
  mrm."name" as model_name,
  case when mdl.uuid is null then 'Model not deployed' else 'Model deployed' end as model_deployment,
  case when mdl.uuid is null then 'Alert' else 'Blocker' end as impact_on_saas_transition,
   concat('enricher expression = ', mee."expression") additional_information 
FROM pg_catalog.pg_proc p
inner join pg_catalog.pg_namespace n ON n.oid = p.pronamespace
inner join  pg_catalog.pg_roles r ON r.oid = p.proowner
inner join mta_enr_expr mee on mee."expression" like '%' || p.proname  || '%'
inner join mta_enricher me on me.uuid = mee.o_enricher 
inner join mta_entity me2 on me2.uuid = me.o_entity 
inner join mta_root_model mrm on  me2.o_model = mrm.uuid 
left outer join mta_model_branch mmb 
on mmb.o_rootmodel = mrm.uuid 
left outer join mta_model_edition mme 
on mme.o_modelbranch = mmb.uuid 
left outer join mta_data_location mdl 
on mdl.r_deployedme = mme.uuid 
WHERE n.nspname not in  ('pg_catalog', 'public', 'extensions', 'information_schema', 'semarchy_repository')
and p.proname not like 'sem_%'
and me.classname = 'SemQLEnricher'

union all 

--Check any validator is using a function or a stored procedure in the xDM model
SELECT 
  'Validators' as assessment_category,
  concat('Validators using Stored proc or functions in the entity [', me."name", ']') as description,
  mc."name" object_name,
  mrm."name" as model_name,
  case when mdl.uuid is null then 'Model not deployed' else 'Model deployed' end as model_deployment,
  case when mdl.uuid is null then 'Alert' else 'Blocker' end as impact_on_saas_transition,
   concat('validator_condition = ', mc."condition") additional_information 
FROM pg_catalog.pg_proc p
inner join pg_catalog.pg_namespace n ON n.oid = p.pronamespace
inner join  pg_catalog.pg_roles r ON r.oid = p.proowner
inner join mta_checkcons mc on mc."condition" like '%' || p.proname  || '%'
inner join mta_entity me on me.uuid = mc.o_entity 
inner join mta_root_model mrm on  me.o_model = mrm.uuid 
left outer join mta_model_branch mmb 
on mmb.o_rootmodel = mrm.uuid 
left outer join mta_model_edition mme 
on mme.o_modelbranch = mmb.uuid 
left outer join mta_data_location mdl 
on mdl.r_deployedme = mme.uuid 
WHERE n.nspname not in  ('pg_catalog', 'public', 'extensions', 'information_schema', 'semarchy_repository')
and p.proname not like 'sem_%'
and mc.classname = 'CheckConstraint'

union all 

--Check if any Dashboard is using a data source external to the xDM database
select 
   'Dashboards' AS assessment_category,
   concat('External datasource used = ', A.ds_name) as description,
    mdo.app_name AS object_name,
    'Not specific to model' AS model_name,
    '' as model_deployment,
    'Complexity' as impact_on_saas_transition,
    concat('JdbcHostName = ', coalesce(A.pool_config::jsonb ->>'url', A.pool_config::jsonb ->'primaryPoolConfig' ->>'url')) as additional_information

from mta_dash_object mdo 
inner join 
(
select pd2."name" as ds_name, pd2.pool_config
from pds_datasource pd2 
where split_part(replace(coalesce(pd2.pool_config::jsonb ->>'url', pd2.pool_config::jsonb ->'primaryPoolConfig' ->>'url'), 'jdbc:postgresql://', ''),':',1)  not in
(
select 
	split_part(replace(coalesce(pd.pool_config::jsonb ->>'url', pd.pool_config::jsonb ->'primaryPoolConfig' ->>'url'), 'jdbc:postgresql://', ''),':',1) as jdbc_host_name 
from mta_data_location mdl 
inner join pds_datasource pd 
on mdl.datasource_name = pd."name" 
)
) A
on trim(split_part(split_part(mdo."content" , E'\n', 1), ':', 2)) = A.ds_name

union all 

--Check any Data Notification is using target type other than REST
select
	'Data Notification' as assessment_category,
	'Data notification target type not REST' as description,
	mdn."name" as object_name,
	mrm."name" model_name,
	'Model deployed' as model_deployment,
    'Blocker'  as impact_on_saas_transition,
	mdn.target_type as additional_information
FROM mta_data_notif mdn
inner join mta_data_location mdl 
on mdn.o_datalocation = mdl.uuid 
inner join mta_model_edition mme 
on mdl.r_deployedme = mme.uuid 
inner join mta_model_branch mmb  
on mme.o_modelbranch = mmb.uuid 
inner join mta_root_model mrm 
on mmb.o_rootmodel = mrm.uuid 
where mdn.target_type <> 'REST'

union all 

--Check any Job notification using File or JMS
select
	'Job Notification' as assessment_category,
	'Job notification using File, JMS, Java notification server' as description,
	mjnp."name" as object_name,
	mrm."name" model_name,
	'Model deployed' as model_deployment,
	'Blocker' as impact_on_saas_transition,
	concat(upper(replace(mns.plugin_id, 'com.semarchy.notification.plugins.convergence.', '')), 'server used')  as additional_information
FROM mta_job_notif_policy mjnp 
inner join mta_notif_server mns 
on mjnp.r_notifserver = mns.uuid 
inner join mta_data_location mdl 
on mjnp.o_datalocation = mdl.uuid 
inner join mta_model_edition mme 
on mdl.r_deployedme = mme.uuid 
inner join mta_model_branch mmb  
on mme.o_modelbranch = mmb.uuid 
inner join mta_root_model mrm 
on mmb.o_rootmodel = mrm.uuid 
where mns.plugin_id  in ('com.semarchy.notification.plugins.convergence.file','com.semarchy.notification.plugins.convergence.jms','com.semarchy.notification.plugin.convergence.mail.jee')

union all 

--Check datasources not used for deployment to be reviewed
select 
	'Datasource' as assessment_category,
	'Datasources not used for model deployment' as descripton,
	"name" as object_name,
	'Not applicable' as model_name,
	'' as model_deployment,
	'For Review' as impact_on_saas_transition,
	'' as additional_information
from pds_datasource 
where "name" not in 
(select datasource_name from mta_data_location) 

union all

--Check if any Custom Plug-ins are defined
select 
	'Custom Plug-in' as assessment_category,
	'' as descripton,
	"name" as object_name,
	'Not applicable' as model_name,
	'' as model_deployment,
	'Blocker' as impact_on_saas_transition,
	concat('Version', "version") as additional_information
from mta_plugin mp  

union all

--Check if Variable Value Provider is created
select 
	'Variable Provider' as assessment_category,
	'' as descripton,
	"name" as object_name,
	'Not applicable' as model_name,
	'' as model_deployment,
	'Blocker' as impact_on_saas_transition,
	plugin_id  as additional_information
from mta_var_val_provider  

union all

--Check if custom sequences are created
select
	'Custom Sequences' assessment_category,
    c.relname AS object_name,
    concat('In schema = ',n.nspname) description,
    'Not applicable' model_name,
    '' as model_deployment,
    'Blocker' impact_on_saas_transition,
    '' additional_information
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_sequence s ON s.seqrelid = c.oid
JOIN pg_sequences seq ON seq.schemaname = n.nspname AND seq.sequencename = c.relname
WHERE c.relkind = 'S'
  AND n.nspname not in ('pg_catalog', 'public', 'extensions', 'information_schema')
  and c.relname not in (
  						'dl_seq_dups_operation',
  						'dl_seq_filter',
  						'wf_seq_step_inst_id',
  						'wf_seq_work_item_id',
  						'wf_seq_workflow_inst_id',
  						'seq_batchid',
  						'seq_datanotiflogid',
  						'seq_loadid',
  						'seq_revision',
  						'seq_matchgrp')
  and c.relname not in 
  (
  	select concat('seq_', lower(me.phys_tabname)) sequence_name
  	from mta_attribute ma 
  	inner join mta_entity me 
  	on ma.o_entity = me.uuid 
  	where case when me.entity_type = 'FUZZY_MATCHED' then ma.fuzz_gold_id_gen_type else ma.id_gen_type end = 'SEQUENCE'
  	union 
  	select concat('ssq_', lower(me.phys_tabname)) sequence_name
  	from mta_attribute ma 
  	inner join mta_entity me 
  	on ma.o_entity = me.uuid 
  	where case when me.entity_type = 'FUZZY_MATCHED' then ma.fuzz_gold_id_gen_type else ma.id_gen_type end = 'SEQUENCE'
  )

  union all 
  
  -- Check views are created in the xdm data location or repository schema
  SELECT 
	'Database Views' as assessment_category,
    table_name AS object_name,
    concat('In schema = ',table_schema) description,
    'Not applicable' model_name,
    '' as model_deployment,
    'Complexity' impact_on_saas_transition,
    '' additional_information   
FROM 
    information_schema.views
WHERE 
    table_schema NOT IN ('pg_catalog', 'information_schema', 'public')

 union all
 
 --Check if custom indexes are created
 SELECT 
    'Custom Indexes' as assessment_category,
    concat('In schema = ',schemaname, ' & table = ', tablename) description,
    indexname AS object_name,
    'Not applicable' model_name,
    '' as model_deployment,
    'To be reviewed' impact_on_saas_transition,
    indexdef additional_information   
FROM 
    pg_indexes
WHERE 
    schemaname NOT IN ('pg_catalog', 'information_schema', 'public')
    and schemaname not in (SELECT table_schema FROM information_schema.tables WHERE table_name = 'mta_repository' ) 
    and substring(indexname, 3, 2) not in ('ae', 'gd', 'gx', 'sa', 'gh', 'dl', 'wf', 'du', 'ga', 'ge', 'gf', 'gi', 'gp', 'md', 'mh', 'mi', 'mx', 'sd', 'se', 'sf', 'um', 'xg', 'ex') 
    and substring(indexname, 1, 2) not in ('pk','fk','ix','i1','i2','i3','i4','i5','i6','i7','i8','i9','i10','i11')
    and tablename not in ('ext_email_domains')

 ) A
 order by 1;
 