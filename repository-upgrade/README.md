# xDM to DM (SDP) Migration Guide

## Overview

This guide provides instructions to migrate data from a local xDM instance to a SDP instance, either in SaaS or on premise (Self Hosted SDP).

## What the toolkit does

The scripts move an xDM instance to the Semarchy Data Platform (SDP / DM) in two separate flows:

| Flow | Entry point | Scope |
|---|---|---|
| **Repository migration** | `migrateRepository` | Platform-wide configuration: roles, users, plugin bundles, image libraries, REST clients, variable providers, properties, notification servers, datasources, dashboards, translations, repository sequences. |
| **Data location migration** | `migrateDataLocation` | One data location at a time: model export/conversion/build, attaching the model to a new data location in SDP, data-location resources (notification policies, continuous loads, purge schedule, data notifications), integration load/batch history, sanitize (upgrade) and `DL_READY`. |

Run the repository migration first. The data location migration expects roles, datasources and the rest of the repository config to exist in SDP already.

> ⚠️ **Data migration:** the data must be migrated before you execute the import steps of the `migrateDataLocation` script.
>
> - For SDP SaaS the data must be migrated before you execute the import command within the `migrateDataLocation` script
> - For SDP Selfhosted, if you intend to migrate the data, same applies as above
> - Do not deploy your converted Data product on the target datasource before completing these scripts entirely. After the successful completion of these scripts your data location will be set to `DL_READY`. After this you can deploy your data product from VS Code or Design-CLI.

## Files at a glance

| File | Lines | Role | Called by |
|---|---|---|---|
| `migrateRepository.sh` | ~190 | **Orchestrator** for the repository flow. Defines the steps, keeps resume state, delegates the work. | Operator |
| `migrateDataLocation.sh` | ~325 | **Orchestrator** for the data-location flow. | Operator |
| `migrateCommons.sh` | ~96 | Shared helpers for the two orchestrators only (step and resume engine, prompts, sem auth checks). | Sourced by both orchestrators |
| `exportXdm.sh` | ~1630 | **Worker**: exports repository and data-location resources from xDM (REST API plus direct SQL on the repository DB) into the workspace. | Both orchestrators |
| `exportXdmModel.sh` | ~630 | **Worker**: exports one model edition (XML plus i18n zip) from xDM. | `migrateDataLocation` |
| `importXdm.sh` | ~2660 | **Worker**: imports workspace content into SDP via the `sem` CLI, Keycloak admin API and DM internal REST endpoints. | Both orchestrators |
| `README.md` | | Operator guide. | |

> ⚠️ **Naming:** the files in the repo end in `.sh`, but the orchestrators refer to them **without** the extension (`. ./migrateCommons`, `run bash exportXdm`, `available importXdm exportXdm exportXdmModel …`). `available` uses `type`, which looks the names up on `PATH`. Wherever the scripts are deployed, they must exist under the extensionless names, and the folder must be on `PATH` (or the names provided some other way) for the `available` check to pass. Keep this in mind when you add or rename a script.

## Pre-requisites

During the migration process, either for a repository migration or a data location migration, the scripts first extract data from the source xDM instance, store them temporarily on disk in the migration workspace (`<user-dir>/.migrate`), and then push them to the target SDP instance.  
Therefore, the machine executing the migration scripts must have access to both the source xDM instance and the target SDP instance.
If that's not the case, you can execute the script to only extract the data from the source instance, transfer the migration workspace to a machine that has access to the target instance, and then reexecute the script to push the data to the target instance. As the current status of the script (the set of already executed steps) is stored in the migration workspace, the script will continue from where it stopped.

### Tools

The migration scripts require the following tools to be installed on the machine executing them:
* **zip**/**unzip**
* **jq** for JSON processing
* **curl** for HTTP requests
* **psql** for accessing the xDM repository database (if using PostgreSQL)
* **sqlcmd** for accessing the xDM repository database (if using MS SQL Server)
* **sqlplus** for accessing the xDM repository database (if using Oracle Database)
* **sem** and **sem-design** CLIs for interacting with DM
* **VS Code** with **DXP extension** (optional, for editing generated model files, but this can be done on another host)

> Note: **sem-design** CLI and **DXP extension** must be in the same version.

### Access to xDM

To export data, the scripts of this folder must be executed on a machine that has access to the xDM instance and the xDM repository.

Required inputs:
* xDM base URL
* xDM API Key with `semarchyConnect` and `semarchyAdmin` roles
* xDM database connection details (host, port, username, password)

### Access to DM REST API in SDP

To import data, the scripts of this folder must be executed on a machine that has access to the SDP instance.

Required inputs:
* SDP tenant base URL
* SDP keycloak base URL

In addition, the `sem` CLI must be authenticated against the target SDP instance with a user (or client) having the 'Site Admin', 'System Admin' and 'xDM Admin' roles.  
⚠️ Migration scripts do not support sem authentication base on API Key. The session must be started using a service account or the device authorization flow.

## Manual Steps

Every script interactively prompts for confirmation before executing any step of the migration process.  
The process can be interrupted at any time (CTRL+C) and restarted later; already executed steps won't be re-executed (current status persisted in `<user-dir>/.migrate/.../status-<xxx>`).  
Some steps are manual (the script prompts for confirmation that the manual step has been completed) and must be performed by the user.

Exemple of manual steps:
* Review and eventually modify exported data files before importing them into SDP
* Review and eventually modify generated model files in the DXP workspace
* Fix secrets in SDP after migration (passwords are not migrated)
* Migrate all Data Location data (SaaS migration)

## Migration of the Repository

To migrate the repository from xDM to SDP, execute the `migrateRepository` script with the required inputs.  
Inputs can be provided as command line options or as environment variables (recommended for sensitive inputs such as API Keys and passwords to avoid exposing them in command line history).  
They are checked only when the script executes the corresponding step, so for instance, if you execute the script to only extract data from xDM (stopping it at the beginning of the first import step), you don't need to provide SDP related inputs.

| Option name            | Environment Variable | Description                                                          |
|------------------------|----------------------|----------------------------------------------------------------------|
| `--xdm-api-key`        | `XDM_API_KEY`        | API Key for accessing xDM REST API                                   |
| `--xdm-url`            | `XDM_URL`            | Base URL of the xDM instance                                         |
| `--xdm-db-host`        | `XDM_DB_HOST`        | Host of the xDM repository schema                                    |
| `--xdm-db-port`        | `XDM_DB_PORT`        | Port of the xDM repository schema                                    |
| `--xdm-db-username`    | `XDM_DB_USERNAME`    | Username for accessing the xDM repository schema                     |
| `--xdm-db-password`    | `XDM_DB_PASSWORD`    | Password for accessing the xDM repository schema                     |
| `--sdp-url`            | `SDP_URL`            | Base URL of the SDP instance                                         |
| `--sdp-tenant-name`    | `SDP_TENANT_NAME`    | Name of the target SDP tenant                                        |
| `--sdp-keycloak-url`   | `SDP_KEYCLOAK_URL`   | Base URL of the Keycloak instance used by the target SDP tenant      |
| `--sequence-increment` | `SEQUENCE_INCREMENT` | Increment to apply to sequences during migration to avoid collisions |
| `--self-hosted`        | `SELF_HOSTED`        | Set this flag if the target SDP instance is Self Hosted (on premise) |
| `--client-id`          | `SEM_CLIENT_ID`      | Client ID used for service account authentication                    |  
| `--client-secret`      | `SEM_CLIENT_SECRET`  | Client Secret used for service account authentication                |  

> **Tip:** instead of exporting each variable by hand, fill in `setEnv.sh` and source it once per shell session (`source ./setEnv.sh`) before running the script.

Examples:

To export the repository from xDM:
```bash
$ ./migrateRepository \
    --xdm-api-key "<API_KEY>" \
    --xdm-db-host "localhost" \
    --xdm-db-port "5432" \
    --xdm-db-username "semarchy_repository" \
    --xdm-db-password "semarchy_repository" \
    --xdm-url "http://localhost:8088/semarchy" \
    --sequence-increment 1000000
```

> **Note:**  
> Here, the `--sequence-increment` is set to `1000000`, which means that all sequences will be incremented by `1,000,000` during the migration.  
> But it's possible to specify a different increment for each sequence with the notation `--sequence-increment batchId:1000000,dataNotifLogId:500000,loadId:1000000,revision:10000000`.

To import the exported repository data into SDP (assuming the export steps have already been executed):
```bash
$ export SDP_URL="https://dm-migration.selfhosted.net"
$ export SDP_TENANT_NAME="dm-migration"
$ export SDP_KEYCLOAK_URL="https://selfhosted.net/auth"
$ ./migrateRepository
```

## Migration of a Data Location

To migrate a data location from xDM to SDP, execute the `migrateDataLocation` script with the required inputs.  
Inputs can be provided as command line options or as environment variables (recommended for sensitive inputs such as API Keys and passwords to avoid exposing them in command line history).
They are checked only when the script executes the corresponding step, so for instance, if you execute the script to only extract data from xDM, you don't need to provide SDP related inputs.

| Option name           | Environment Variable | Description                                                          |
|-----------------------|----------------------|----------------------------------------------------------------------|
| `--xdm-api-key`       | `XDM_API_KEY`        | API Key for accessing xDM REST API                                   |
| `--xdm-url`           | `XDM_URL`            | Base URL of the xDM instance                                         |
| `--xdm-db-host`       | `XDM_DB_HOST`        | Host of the xDM repository schema                                    |
| `--xdm-db-port`       | `XDM_DB_PORT`        | Port of the xDM repository schema                                    |
| `--xdm-db-username`   | `XDM_DB_USERNAME`    | Username for accessing the xDM repository schema                     |
| `--xdm-db-password`   | `XDM_DB_PASSWORD`    | Password for accessing the xDM repository schema                     |
| `--sdp-url`           | `SDP_URL`            | Base URL of the SDP instance                                         |
| `--sdp-tenant-name`   | `SDP_TENANT_NAME`    | Name of the target SDP tenant                                        |
| `--sdp-keycloak-url`  | `SDP_KEYCLOAK_URL`   | Base URL of the Keycloak instance used by the target SDP tenant      |
| `--legacy-keycloak`   | `LEGACY_KEYCLOAK`    | Set this flag to use legacy keycloak APIs                            |
| `--data-location`     | `DATA_LOCATION`      | Name of the data location to migrate                                 |
| `--datasource`        | `DATASOURCE`         | Name of the datasource to use for the data location                  |
| `--model-name`        | `MODEL_NAME`         | Name of the model to export/convert/import                           |
| `--model-edition-key` | `MODEL_EDITION_KEY`  | Edition key of the model to export (optional)                        |
| `--model-root-folder` | `MODEL_ROOT_FOLDER`  | Model root folder in DXP                                             |
| `--self-hosted`       | `SELF_HOSTED`        | Set this flag if the target SDP instance is Self Hosted (on premise) |
| `--client-id`         | `SEM_CLIENT_ID`      | Client ID used for service account authentication                    |  
| `--client-secret`     | `SEM_CLIENT_SECRET`  | Client Secret used for service account authentication                |  

> Notes:
> - The `--model-edition-key` is only necessary if the script needs to export and convert the model from xDM.  
> If the model is already present in the model root folder (converted by another mean), the script will use it directly.
> - `--client-id` and `--client-secret` should both be provided only if the sem CLI is not already authenticated (session, profile) against the target SDP platform.

> **Tip:** instead of exporting each variable by hand, fill in `setEnv.sh` and source it once per shell session (`source ./setEnv.sh`) before running the script.


```bash
./migrateDataLocation \
  --xdm-api-key "<API_KEY>" \
  --xdm-url "http://localhost:8088/semarchy" \
  --xdm-db-host "localhost" \
  --xdm-db-port "5433" \
  --xdm-db-username "semarchy_repository" \
  --xdm-db-password "semarchy_repository" \
  --sdp-url "https://dm-migration.selfhosted.net" \
  --sdp-tenant-name "dm-migration" \
  --sdp-keycloak-url "https://sefhosted.net/auth" \
  --data-location "ProductRetailDemo" \
  --datasource "SEMARCHY_PRODUCT_RETAIL_MDM" \
  --model-name "ProductRetailDemo" \
  --model-edition-key "0.0" \
  --model-root-folder "$HOME/DXP/ProductRetailDemo"
```
