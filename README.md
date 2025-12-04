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
- Discovers only clusters that actually contain the given deployments
- Lets you:
  - Restart on **all matching clusters**, or  
  - Restart on **selected clusters only**
- **Dry Run mode** (no changes made, simulates everything)
- Uses `az aks get-credentials --admin` (no `kubelogin` / AAD prompt)
- Live rollout monitoring for each deployment (up to 10 minutes)
- Tracks:
  - Per-deployment start time, end time, and downtime
  - Overall script start time, end time, and total duration
- Exports results to CSV for auditing

---

## Prerequisites

- **PowerShell** (5.1+ or PowerShell 7 recommended)
- **Azure CLI** (`az`) installed and logged in
- **kubectl** installed and accessible in `PATH`
- Permissions:
  - Read AKS clusters and get credentials
  - Permission to restart deployments in the target namespaces

---

## Script Location

By default, the main script is:

```text
scripts/aks-restart.ps1
