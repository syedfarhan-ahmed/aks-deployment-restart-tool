# =========================
# AKS Deployment Restart Script
# - Optional tag filter (OR logic across multiple tags)
# - Multi-deployment support
# - Cross-subscription AKS discovery
# - Dry Run mode
# - Live rollout monitoring (10 min)
# - Per-deployment downtime tracking
# - Overall script start/end/duration
# - Shows status for ALL selected clusters/deployments once,
#   then single global restart confirmation
# =========================

function Login-ToAzure {
    Write-Host "Logging in to Azure..."
    az login
}

function Get-AksClustersByTags {
    param (
        [object[]]$tagFilters,
        [bool]$UseTags
    )

    Write-Host "Retrieving subscriptions..."
    $subscriptions = az account list -o json | ConvertFrom-Json

    if (-not $subscriptions -or $subscriptions.Count -eq 0) {
        Write-Host "No subscriptions found for this account."
        return @()
    }

    $allClusters = @()
    $useFilter = $UseTags -and $tagFilters -and $tagFilters.Count -gt 0

    foreach ($sub in $subscriptions) {
        $subId   = $sub.id
        $subName = $sub.name

        Write-Host "Checking subscription: $subName ($subId)..."

        $clusters = az aks list --subscription $subId -o json | ConvertFrom-Json
        if (-not $clusters) { continue }

        foreach ($c in $clusters) {
            $includeCluster = $true

            if ($useFilter) {
                $includeCluster = $false
                $tags = $c.tags

                if ($tags) {
                    foreach ($tf in $tagFilters) {
                        $key   = $tf.Key
                        $value = $tf.Value

                        $tagProp = $tags.PSObject.Properties | Where-Object { $_.Name -eq $key }
                        if ($tagProp -and $tagProp.Value -eq $value) {
                            # OR logic: cluster is included if ANY tag matches
                            $includeCluster = $true
                            break
                        }
                    }
                }
            }

            if ($includeCluster) {
                $c | Add-Member -NotePropertyName subscriptionId   -NotePropertyValue $subId   -Force
                $c | Add-Member -NotePropertyName subscriptionName -NotePropertyValue $subName -Force
                $allClusters += $c
            }
        }
    }

    return $allClusters
}

function Get-DeploymentsInCluster {
    param (
        [string]$clusterName,
        [string]$resourceGroup,
        [string]$subscriptionId
    )

    Write-Host "Fetching deployments from cluster: $clusterName (RG: $resourceGroup, Sub: $subscriptionId)..."
    
    az aks get-credentials `
        --subscription "$subscriptionId" `
        --resource-group "$resourceGroup" `
        --name "$clusterName" `
        --overwrite-existing `
        --admin | Out-Null

    $deployments = kubectl get deployments --all-namespaces -o json | ConvertFrom-Json
    return $deployments
}

function Show-DeploymentStatusTable {
    param (
        [object]$deploymentObject,
        [string]$clusterName
    )

    $depName   = $deploymentObject.metadata.name
    $namespace = $deploymentObject.metadata.namespace

    Write-Host ""
    Write-Host "===== CURRENT STATUS: Cluster '$clusterName' | Namespace '$namespace' | Deployment '$depName' ====="

    # Deployment-level info (we already have object, but get JSON again for status fields)
    $depJson = kubectl get deployment $depName -n $namespace -o json 2>$null | ConvertFrom-Json
    if ($depJson) {
        $desired    = $depJson.spec.replicas
        if (-not $desired -or $desired -lt 1) { $desired = 1 }
        $available  = $depJson.status.availableReplicas
        $ready      = $depJson.status.readyReplicas
        $updated    = $depJson.status.updatedReplicas

        Write-Host ("Replicas -> Desired: {0}, Updated: {1}, Ready: {2}, Available: {3}" -f `
            $desired, `
            ($updated   -as [string]), `
            ($ready     -as [string]), `
            ($available -as [string]))
    } else {
        Write-Host "Unable to fetch deployment JSON details."
    }

    # Pod status table
    $pods = kubectl get pods -n $namespace --selector=app=$depName -o json 2>$null | ConvertFrom-Json
    if ($pods -and $pods.items -and $pods.items.Count -gt 0) {
        $header = "{0,-50} {1,-12} {2,-10} {3,-20}" -f "POD", "PHASE", "READY", "DETAIL"
        $line   = "-" * ($header.Length)
        Write-Host ""
        Write-Host $header
        Write-Host $line

        foreach ($p in $pods.items) {
            $podName = $p.metadata.name
            $phase   = $p.status.phase

            $cs = $p.status.containerStatuses
            if ($cs) {
                $readyCount = ($cs | Where-Object { $_.ready }).Count
                $totalCount = $cs.Count
                $readyText  = "$readyCount/$totalCount"
                $detail     = $null

                $waiting = $cs | Where-Object { $_.state.waiting } | Select-Object -First 1
                if ($waiting) {
                    $detail = $waiting.state.waiting.reason
                } elseif ($cs[0].state.terminated) {
                    $detail = $cs[0].state.terminated.reason
                } else {
                    $detail = ""
                }
            } else {
                $readyText = "0/0"
                $detail    = ""
            }

            # Color logic
            $color = "White"
            if ($phase -eq "Running") {
                $color = "Green"
            } elseif ($phase -eq "Pending") {
                $color = "Yellow"
            } else {
                $color = "Red"
            }

            if ($detail -eq "CrashLoopBackOff") {
                $color = "Red"
            }

            $row = "{0,-50} {1,-12} {2,-10} {3,-20}" -f $podName, $phase, $readyText, $detail
            Write-Host $row -ForegroundColor $color
        }
    } else {
        Write-Host ""
        Write-Host "No pods found for selector app=$depName"
    }

    Write-Host "====================================================================="
    Write-Host ""
}

function Restart-DeploymentsInCluster {
    param (
        [string]  $clusterName,
        [string]  $resourceGroup,
        [string]  $subscriptionId,
        [string]  $subscriptionName,
        [string[]]$deploymentNames,
        [string]  $tags,
        [string]  $requestedBy,
        [bool]    $DryRun = $false
    )

    $restartStatus = @()

    $deploymentsJson = Get-DeploymentsInCluster -clusterName $clusterName -resourceGroup $resourceGroup -subscriptionId $subscriptionId
    if (-not $deploymentsJson -or -not $deploymentsJson.items) {
        Write-Host "No deployments found in cluster $clusterName."
        return $restartStatus
    }

    $matchingDeployments = $deploymentsJson.items | Where-Object { $deploymentNames -contains $_.metadata.name }
    if (-not $matchingDeployments -or $matchingDeployments.Count -eq 0) {
        Write-Host "None of the specified deployments exist in cluster $clusterName."
        return $restartStatus
    }

    foreach ($deployment in $matchingDeployments) {
        $depName   = $deployment.metadata.name
        $namespace = $deployment.metadata.namespace

        Write-Host ""
        Write-Host "Restarting deployment '$depName' in namespace '$namespace' on cluster '$clusterName'..."

        $startTime = Get-Date

        $status = New-Object PSObject -property @{
            SubscriptionId   = $subscriptionId
            SubscriptionName = $subscriptionName
            Cluster          = $clusterName
            ResourceGroup    = $resourceGroup
            Deployment       = $depName
            Namespace        = $namespace
            Tags             = $tags
            RequestedBy      = $requestedBy
            Status           = 'In Progress'
            StartTime        = $startTime
            EndTime          = $null
            DowntimeSeconds  = $null
        }

        $restartStatus += $status

        if ($DryRun) {
            Write-Host "DRY RUN: Skipping actual restart for '$depName'."
            $status.Status = 'DryRun'
            $status.EndTime = $startTime
            $status.DowntimeSeconds = 0
            continue
        }

        # Do the restart
        kubectl rollout restart deployment $depName --namespace $namespace | Out-Null

        # Live monitoring
        $maxWaitSeconds      = 600
        $pollIntervalSeconds = 5
        $elapsedSeconds      = 0
        $desiredReplicas     = $deployment.spec.replicas
        if (-not $desiredReplicas -or $desiredReplicas -lt 1) { $desiredReplicas = 1 }

        $allRunning = $false

        while ($elapsedSeconds -lt $maxWaitSeconds) {
            Start-Sleep -Seconds $pollIntervalSeconds
            $elapsedSeconds += $pollIntervalSeconds

            $podsJson = kubectl get pods --namespace $namespace --selector=app=$depName -o json 2>$null | ConvertFrom-Json

            $runningCount = 0
            if ($podsJson -and $podsJson.items) {
                $runningPods = $podsJson.items | Where-Object { $_.status.phase -eq 'Running' }
                if ($runningPods) { $runningCount = $runningPods.Count }
            }

            Write-Host ("[{0:00}:{1:00}] Cluster: {2} | Deployment: {3} | Running {4}/{5}" -f `
                        [int]($elapsedSeconds / 60),
                        ($elapsedSeconds % 60),
                        $clusterName,
                        $depName,
                        $runningCount,
                        $desiredReplicas)

            if ($runningCount -ge $desiredReplicas) {
                $allRunning = $true
                break
            }
        }

        $endTime = Get-Date
        $status.EndTime = $endTime
        $status.DowntimeSeconds = [int]($endTime - $startTime).TotalSeconds

        if ($allRunning) {
            Write-Host "Deployment '$depName' is back to Running state in cluster '$clusterName'."
            $status.Status = 'Completed'
        } else {
            Write-Host "Timeout: deployment '$depName' did not reach full Running state within 10 minutes in cluster '$clusterName'."
            $status.Status = 'Timeout'
        }
    }

    return $restartStatus
}

function Main {
    # Overall script timing
    $scriptStart = Get-Date

    Login-ToAzure
    
    # 0) Ask whether to use tags
    Write-Host ""
    $useTagsInput = Read-Host "Do you want to filter clusters by tags? (y/n)"
    $useTags = $useTagsInput -match '^[Yy]$'

    $tagFilters = @()
    $tagsString = ""

    if ($useTags) {
        Write-Host ""
        Write-Host "Configure TAG filters to select clusters."
        Write-Host "You will be asked for TAG NAME and VALUE."
        Write-Host "Press Enter on TAG NAME when you're done adding tags."

        $tagIndex = 1
        while ($true) {
            $tagName = Read-Host "Enter TAG $tagIndex NAME (or press Enter to finish)"
            if ([string]::IsNullOrWhiteSpace($tagName)) {
                break
            }

            $tagValue = Read-Host "Enter TAG $tagIndex VALUE for '$tagName'"
            if ([string]::IsNullOrWhiteSpace($tagValue)) {
                Write-Host "Empty value is not valid, skipping this tag."
            } else {
                $tagFilters += [PSCustomObject]@{ Key = $tagName.Trim(); Value = $tagValue.Trim() }
            }

            $more = Read-Host "Do you want to add another tag? (y/n)"
            if ($more -notmatch '^[Yy]$') { break }

            $tagIndex++
        }

        if ($tagFilters.Count -eq 0) {
            Write-Host "No valid tags provided. Since you chose tag filtering, exiting."
            return
        }

        $tagsString = ($tagFilters | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
    }
    else {
        Write-Host ""
        Write-Host "Tag filtering disabled. All AKS clusters in all subscriptions will be considered."
    }

    # 1) Deployment names
    Write-Host ""
    Write-Host "Enter deployment names to target (comma-separated)."
    Write-Host "Example: api-deployment,worker-deployment,frontend-deployment"
    $depInput = Read-Host "Deployment names"

    $deploymentNames = @()
    foreach ($d in $depInput -split ',') {
        $dd = $d.Trim()
        if ($dd) { $deploymentNames += $dd }
    }

    if ($deploymentNames.Count -eq 0) {
        Write-Host "No valid deployment names provided. Exiting."
        return
    }

    # 2) Audit tracking
    $requestedBy = Read-Host "Enter your name or ID (for audit tracking)"

    # 3) DRY RUN
    $dryRunInput = Read-Host "Enable DRY RUN mode? (y/n)"
    $isDryRun = $dryRunInput -match '^[Yy]$'
    if ($isDryRun) {
        Write-Host ""
        Write-Host "================ DRY RUN MODE ENABLED ================"
        Write-Host "No actual restarts will be performed. This will only show what WOULD happen."
        Write-Host "======================================================"
    }

    # 4) Collect clusters
    Write-Host ""
    if ($useTags) {
        Write-Host "Filtering clusters across ALL subscriptions by tags (OR logic): $tagsString"
    } else {
        Write-Host "Collecting ALL AKS clusters across ALL subscriptions (no tag filter)..."
    }

    $candidateClusters = Get-AksClustersByTags -tagFilters $tagFilters -UseTags:$useTags
    if (-not $candidateClusters -or $candidateClusters.Count -eq 0) {
        if ($useTags) {
            Write-Host "No AKS clusters found with tags '$tagsString' in any subscription."
        } else {
            Write-Host "No AKS clusters found in any subscription."
        }
        return
    }

    Write-Host ""
    Write-Host "Checking which clusters actually contain ANY of the deployments: $($deploymentNames -join ', ')"
    $clustersWithDeployment = @()

    foreach ($cluster in $candidateClusters) {
        $clusterName      = $cluster.name
        $resourceGroup    = $cluster.resourceGroup
        $subscriptionId   = $cluster.subscriptionId
        $subscriptionName = $cluster.subscriptionName

        $deploymentsJson = Get-DeploymentsInCluster -clusterName $clusterName -resourceGroup $resourceGroup -subscriptionId $subscriptionId
        if (-not $deploymentsJson -or -not $deploymentsJson.items) { continue }

        $matching = $deploymentsJson.items | Where-Object { $deploymentNames -contains $_.metadata.name }
        if ($matching -and $matching.Count -gt 0) {
            $namesInCluster = $matching | ForEach-Object { $_.metadata.name } | Sort-Object -Unique
            $clusterInfo = [PSCustomObject]@{
                name                = $clusterName
                resourceGroup       = $resourceGroup
                subscriptionId      = $subscriptionId
                subscriptionName    = $subscriptionName
                matchingDeployments = $namesInCluster
            }
            $clustersWithDeployment += $clusterInfo
        }
    }

    if ($clustersWithDeployment.Count -eq 0) {
        Write-Host ""
        if ($useTags) {
            Write-Host "No clusters (matching tags '$tagsString') contain any of the specified deployments."
        } else {
            Write-Host "No clusters contain any of the specified deployments."
        }
        return
    }

    # 5) List clusters + selection
    Write-Host ""
    if ($useTags) {
        Write-Host "Clusters (tag-filtered) that ALSO contain the specified deployments:"
    } else {
        Write-Host "Clusters (no tag filter) that contain the specified deployments:"
    }

    for ($i = 0; $i -lt $clustersWithDeployment.Count; $i++) {
        $c = $clustersWithDeployment[$i]
        $deps = $c.matchingDeployments -join ', '
        Write-Host "[$i] $($c.name) | RG: $($c.resourceGroup) | Sub: $($c.subscriptionName) ($($c.subscriptionId)) | Deployments: $deps"
    }

    Write-Host ""
    Write-Host "Cluster selection options:"
    Write-Host " - Type 'all' to process ALL listed clusters"
    Write-Host " - Or specify indices (e.g. 0 or 0,2,3)"
    $choice = Read-Host "Enter choice"

    $selectedClusters = @()
    if ($choice.Trim().ToLower() -eq "all") {
        $selectedClusters = $clustersWithDeployment
        Write-Host "Selected ALL clusters that contain the specified deployments."
    }
    else {
        $indices = $choice -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^\d+$' } |
            ForEach-Object { [int]$_ }

        foreach ($i in $indices) {
            if ($i -ge 0 -and $i -lt $clustersWithDeployment.Count) {
                $selectedClusters += $clustersWithDeployment[$i]
            } else {
                Write-Host "Index $i is out of range and will be ignored."
            }
        }
    }

    if ($selectedClusters.Count -eq 0) {
        Write-Host "No valid clusters selected. Exiting."
        return
    }

    # 6) SHOW STATUS FOR ALL SELECTED CLUSTERS + DEPLOYMENTS
    Write-Host ""
    Write-Host "================ CURRENT STATUS FOR SELECTED CLUSTERS / DEPLOYMENTS ================"

    foreach ($cluster in $selectedClusters) {
        $clusterName      = $cluster.name
        $resourceGroup    = $cluster.resourceGroup
        $subscriptionId   = $cluster.subscriptionId
        $subscriptionName = $cluster.subscriptionName

        Write-Host ""
        Write-Host "---- Cluster: $clusterName | RG: $resourceGroup | Sub: $subscriptionName ----"

        # Get deployments again for this cluster to show full status, limited to matchingDeployments
        $deploymentsJson = Get-DeploymentsInCluster -clusterName $clusterName -resourceGroup $resourceGroup -subscriptionId $subscriptionId
        if (-not $deploymentsJson -or -not $deploymentsJson.items) {
            Write-Host "No deployments found in this cluster."
            continue
        }

        $matching = $deploymentsJson.items | Where-Object { $cluster.matchingDeployments -contains $_.metadata.name }
        if (-not $matching -or $matching.Count -eq 0) {
            Write-Host "No matching deployments found in this cluster (unexpected)."
            continue
        }

        foreach ($dep in $matching) {
            Show-DeploymentStatusTable -deploymentObject $dep -clusterName $clusterName
        }
    }

    Write-Host "============================================================================"
    Write-Host ""

    # 7) Global confirmation
    Write-Host "You are about to restart ALL of the deployments shown above in ALL selected clusters."
    $confirm = Read-Host "Proceed with restart for ALL? (y/n)"
    if (-not ($confirm -match '^[Yy]$')) {
        Write-Host "Operation cancelled. No deployments restarted."
        return
    }

    # 8) Restart / Dry-run
    $allRestartStatus = @()

    foreach ($cluster in $selectedClusters) {
        Write-Host ""
        Write-Host "==============================="
        Write-Host "Processing cluster: $($cluster.name)"
        Write-Host "RG: $($cluster.resourceGroup)"
        Write-Host "Subscription: $($cluster.subscriptionName) ($($cluster.subscriptionId))"
        Write-Host "Target deployments: $($cluster.matchingDeployments -join ', ')"
        Write-Host "==============================="

        $result = Restart-DeploymentsInCluster `
            -clusterName $cluster.name `
            -resourceGroup $cluster.resourceGroup `
            -subscriptionId $cluster.subscriptionId `
            -subscriptionName $cluster.subscriptionName `
            -deploymentNames $cluster.matchingDeployments `
            -tags $tagsString `
            -requestedBy $requestedBy `
            -DryRun:$isDryRun

        if ($result) { $allRestartStatus += $result }
    }

    # 9) Script end timing + enrich results + CSV log
    $scriptEnd = Get-Date
    $scriptDurationSeconds = [int]($scriptEnd - $scriptStart).TotalSeconds

    if ($allRestartStatus.Count -gt 0) {
        foreach ($s in $allRestartStatus) {
            $s | Add-Member -NotePropertyName ScriptStartTime       -NotePropertyValue $scriptStart -Force
            $s | Add-Member -NotePropertyName ScriptEndTime         -NotePropertyValue $scriptEnd   -Force
            $s | Add-Member -NotePropertyName ScriptDurationSeconds -NotePropertyValue $scriptDurationSeconds -Force
        }

        $path = "DeploymentRestartStatus.csv"
        $allRestartStatus | Export-Csv -Path $path -NoTypeInformation

        Write-Host ""
        if ($isDryRun) {
            Write-Host "DRY RUN summary written to $path (open in Excel). No actual restarts were performed."
        } else {
            Write-Host "Restart log written to $path (open in Excel)."
        }
    } else {
        Write-Host ""
        Write-Host "No deployments were processed. CSV file not created."
    }

    # 10) Print script timing summary
    Write-Host ""
    Write-Host "Script started at : $scriptStart"
    Write-Host "Script ended at   : $scriptEnd"
    Write-Host "Script duration   : $scriptDurationSeconds seconds"
}

Main
