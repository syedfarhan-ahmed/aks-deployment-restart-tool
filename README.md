# aks-deployment-restart-tool
This script scans all Azure subscriptions, finds AKS clusters by optional tag filters, locates specified deployments, and restarts them with live rollout monitoring. It supports dry-run mode, cluster selection, and exports full audit details, downtime, and script duration to CSV.
