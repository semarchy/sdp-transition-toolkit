SDP Transition Assessment Methodology


# General Organization

Transition assessment is generally conducted by a member of the Semarchy Professional Services team per agreement with the customer and/or implementation partner. The goal of this assessment is to review existing Semarchy implementation and identify risks and impacts of the SDP transition.

If required, this assessment will also provide a high-level effort estimate based on the best of our knowledge and experience with similar projects. This estimate might be adjusted by the System integrator who will perform the migration. 

As part of the conclusions for the assessment Semarchy might recommend the migration target that is most suitable for the customer (SaaS or self-hosted).


## Prerequisites

In order to be able to conduct the SDP Transition assessment a member of the Semarchy Professional Services team must have access to:

- Existing xDM data models export
- Information about the existing xDM installation (version, architecture)
- Information about data flows around xDM


# Assessment Methodology

This chapter describes aspects to verify around the customer implementation and the impact each of those has on the SDP transition effort and target. 


## Discovery Call

As the  first step, a discovery call is recommended. This call aims to coordinate the assessment and gather initial information about the current state of the system.

The following personas are required for this call:
- Semarchy Solution Architect
- Client’s Solution Architect

During this call the following information must be gathered:

**xDM Version**
xDM 2024.1.x and 2025.1.x are supported for the direct migration. If the customer has an earlier version of xDM tool, they must first upgrade to a newer version.

**DB Technology**
While self-hosted SDP supports the same DB providers as xDM for data location, the repository is now PostgreSQL only. Data locations on SaaS are also PostgreSQL only.
It is important to evaluate presence of DB functions specific to other DB providers especially for the migration target SaaS.

**Installation Type and Architecture**
SDP self-hosted requires Kubernetes or OpenShift installation as well as connected Kafka and OpenSearch instances. Knowing the current architecture of xDM helps to evaluate the change management effort for the customer. 

For example, if xDM is currently installed on a Kubernetes cluster, the upgrade to SDP will be easier to conduct as the customer already has experience on managing Kubernetes, compared to the case where xDM is installed on a VM.

It is also important here to check requirements for a specific platform for self-hosted targets:
- Kubernetes engine
- OpenSearch/ElastiSearch usage allowed
- Kafka usage allowed
- Terraform usage allowed


**Number of Applications and Data Locations to Migrate**

The number of applications and data locations to migrate has a direct impact on the migration effort and cost. 
It is also important to plan accordingly the migration approach in phases based on the number and business impact of the applications.

**Data Model Versions to Migrate**

The customer might want to migrate several data model versions to keep historical data. This impacts planning as it will require to do data model migration step several times.

**Number of Golden Records**

For SaaS targeted migration and for the self-hosted out of place migrations number of golden records will impact the duration of the data migration step and indirectly of the time the parallel run will take.

**Skills and Methodology the Customer has In-House**

SDP brings requirements for new skills compared to xDM:
- Kubernetes/OpenShift knowledge (for self-hosted migration target)
- VS Code usage knowledge
- AI agents collaborative tools. 

It is required to evaluate the knowledge that the customer already has in house and what support they might require additionally from Semarchy or Official Partners.

**Initial Migration Target and Preferences**

If the customer’s preference is to go to SaaS, the assessment needs to pay additional attention to critical points around SaaS implementation. If the preference is to go with self-hosted, most of the questions will be around infrastructure and architecture.


## Offline Assessment

Offline assessment is performed based on the xDM data model provided. To speed up the audit process, Semarchy SA can request the customer to run PS scripts - [PostgreSQL](pre-migration_assessment_postgres_queries.sql), [Oracle](pre_migration_assessment_oracle_queries.sql), [SQL Server](pre_migration_assessment_sqlserver_queries.sql) - to automatically evaluate the presence of some sensitive customizations inside. 


### Database Customizations

#### Indexes

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|-------------------------|------------------------|----------------------------------------------------------------------|
| Complexity              | No impact              | As on SDP SaaS there is no direct access to the database, custom indexes can not be migrated directly. They can, however, be recreated upon request by Semarchy IT team |

#### Stored Procedures

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|-------------------------|------------------------|----------------------------------------------------------------------|
| Blocker                 | No impact              | As on SDP SaaS there is no direct access to the database, stored procedures can not be migrated. For the customer project it is required to identify all such procedures and the business need behind to find a suitable solution to replace. |

It is recommended to create a separate list of the procedures and use cases covered for future reference and sharing with the Semarchy Product team. 


#### SQL Functions

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Blocker            | No impact        | As on SDP SaaS there is no direct access to the database, stored procedures can not be migrated. For the customer project it is required to identify all such functions and the business need behind to find a suitable solution to replace.|

It is recommended to create a separate list of the functions and use cases covered for future reference and sharing with the Semarchy Product team. 

#### Sequences

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | No impact        | During the data migration to SaaS the migration tool will take into account sequences present on data locations. It is required to include in the post-migration checks a step to review sequences.|


#### Views

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Blocker                | No impact            | As on SDP SaaS there is no direct access to the database, views are not allowed. It is recommended to identify alternatives based on the usage and business need. | 


#### SQL Hooks

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Blocker            | No impact        | As on SDP SaaS there is no direct access to the database, stored procedures can not be migrated. For the customer project it is required to identify all such functions and the business need behind to find a suitable solution to replace. |

It is recommended to create a separate list of the SQL hooks and use cases covered for future reference and sharing with the Semarchy Product team. 


#### Other Database Customizations

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | Complexity       | As on SDP SaaS there is no direct access to the database, any customizations done around the data location or repository cannot be migrated (for example, using Oracle scheduler or mail service). The customer needs to work with Semarchy to identify business cases and possible workarounds.For self-hosted the impact is limited to the cases where the customer is using Oracle or SQL Server and customizations on the repository that aren’t compatible with PostgreSQL | 


### Workflows

Data Driven workflows are supported by the automated migration tooling provided by Semarchy. However, the ongoing development of such workflows needs to be part of the change management process as there is no longer a visual drag and drop style editor.

### Legacy Workflows

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | Complexity       | Prior migration to SDP, all legacy workflows must be migrated to the Data Driven. Please, note that there might not be a feature parity between the two. | 


### Data Integration

As a general rule, Data integration requirements bring **complexity for SaaS migrations**. The customer will need to **expose publicly the endpoints that they wish to call from Semarchy SDP through the REST API**.

#### JMS/Kafka/Azure Service Bus 

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Blocker            | No impact        | SDP SaaS allows integration only through REST API, so customers using JMS/Kafka/ASB to do data notifications or other types of integration will need to redesign their data flow | 


#### Inbound Database Integrations

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | No impact        | On SDP SaaS the database being inaccessible, inbound integration needs to happen through alternative channels, mainly REST API.On self-hosted the customer needs to mind the fact that the repository is in PostgreSQL, so if the data location(s) is on a different database, it is no longer possible to use SQL scripts that query both the repository (for example, for load ID) and the data location | 


#### Outbound database integrations

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | Complexity       | On SDP SaaS the database being inaccessible, outbound integration needs to happen through alternative channels, mainly REST API. | 

#### Real-time integration with High Up-Time Requirements (e.g., NSC)

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | No impact        | In order to support near real-time integration requirements, SDP SaaS must be sized accordingly. Semarchy team needs to have metrics on the number of call to handle per period of time, types of data exported or imported, complexity of the data certification process and volume of the data in order to correctly size the tenant. | 


### **Other xDM Customizations**

#### Migrating database technologies
| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | Complexity       | On SDP SaaS, both for the repository and for the data location, the only database technology supported is PostgreSQL. If the customer is using another database with xDM the migration estimation needs to account for: Specific functions not supported on PostgreSQL; SQL scripts calling both repository and data location; Specific data types and data conversion; Change management for backup & restore (for self-hosted repository) | 


#### Dashboards Built on Top of Repository Tables

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Blocker            | No impact        | On SDP SaaS the database being inaccessible, dashboards using repository tables are not supported.Discussion ongoing with the product team to define alternatives. | 


#### Custom Java Plugins

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Blocker            | No impact        | On SDP SaaS custom Java plugins are not allowed. The customer will need to work with the Semarchy PS team to identify business cases and possible alternative implementation | 


### Customer Infrastructure

#### Customers with High Security Requirements

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | Complexity       | High security requirements can impact SDP migration choice on several levels. |

For SaaS targets, main questions should be:

* Types of end points to call from SaaS (only public are supported)
* Security and certification requirements to match Semarchy official ones

For self-hosted targets:

* air gap environment
* usage of certificates signed by a private CA
* impossibility to use Terraform/Kubernetes side cars

#### Large Model or Number of Records

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | No impact        | In order to support large data volumes, SDP SaaS must be sized accordingly.|

Semarchy team needs to have metrics on:

* Number of entities
* Number of golden and master records
* Complexity of job certification 

#### On-prem SSO such as LDAP or Active Directory

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Blocker            | Complexity       | Usage of an on-prem SSO is not supported on SDP SaaS as it would be impossible to establish secure connection.Integration on SDP self-hosted might be possible but should be identified on the assessment stage and reviewed with the product team. | 


#### Change Management Around Skills and Personas

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | Complexity       | SDP brings requirements for upskill on several topics. These requirements need to be addressed as part of the project to ensure to have right resources available. | 

Main topics: 

* VS Code
* Yaml
* Usage of Agentic AI
* CI/CD and DevOps
* Kubernetes (self-hosted)

#### High IT Security Around Desktop Installations

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | Complexity       | If the customer has security requirements around the installation of the software on company computers (for example, validation by the IT or security team), these need to be taken into account and factored into migration planning.  | 

SDP design requires installation on the developer workstation of the following components:

* VS Code
* Semarchy Extension (official marketplace)
* Semarchy CLI



#### Infrastructure Costs and Complexity

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| No impact          | Complexity       | SDP SaaS allows to lighten infrastructure costs. Self-hosted installation, on the other hand, requires several heavy prerequisites compared to xDM. In case of a Cloud installation costs must be evaluated by the customer based on their usage and contract with the Cloud provider. |

Main cost components that weren't present for xDM:

* Kubernetes
* Event streaming system
* Search & log management system 


### SaaS Specifics

#### Role Transition

| **Impact on SaaS**      | **Impact on SH**       | **Details** |
|------------------------|----------------------|----------------------------------------------------------------------|
| Complexity         | No impact        | In case the customer defined several custom roles on their xDM installation and wants them migrated to the platform, Semarchy will need to gather this requirement prior migration and work with the IT team to ensure smooth transition | 
