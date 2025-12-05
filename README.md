# AKS Deployment Restart Orchestrator

This repository contains a PowerShell script that automates the safe discovery and restart of Kubernetes deployments across Azure Kubernetes Service (AKS) clusters in large, multi-subscription environments.

The script is fully interactive and designed for Cloud, DevOps, and SRE teams who need a controlled, auditable, and scalable way to restart deployments across many clusters.

---

## Features

- Scans **all Azure subscriptions** visible to the logged-in user
- Optional **tag-based cluster filtering**
  - Supports **multiple tags**
  - Uses **OR logic** → a cluster is included if it matches *any* of the tags
  - Can also run **without tags** (all AKS clusters)
- Supports **multiple deployment names** (comma-separated)
- Automatically discovers only clusters that actually contain the given deployments
- Lets you:
  - Process **all matching clusters**, or  
  - **Select specific clusters** by index
- Shows **current status for all selected deployments in all selected clusters** *before* any restart:
  - Deployment replica summary (desired, updated, ready, available)
  - Pod-level status table per deployment (color-coded by phase)
- Single **global confirmation** to restart **all** shown deployments
- **Dry Run mode** (no changes made, simulates everything)
- Uses `az aks get-credentials --admin` (no `kubelogin` / AAD prompt)
- Live rollout monitoring for each deployment (up to 10 minutes)
- Tracks:
  - Per-deployment start time, end time, and downtime
  - Overall script start time, end time, and total duration
- Exports results to CSV for auditing

---

## Prerequisites

- **PowerShell**
  - Windows PowerShell 5.1+ or PowerShell 7+
- **Azure CLI** (`az`) installed and in `PATH`
- **kubectl** installed and in `PATH`
- Permissions:
  - Read access to AKS clusters and ability to run `az aks get-credentials --admin`
  - Permissions to restart deployments in the relevant namespaces

---

## Script Location

By convention, the script lives at:

```text
.\aks-restart.ps1

