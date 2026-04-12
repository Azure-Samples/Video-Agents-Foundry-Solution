# Observability Features

Observability is critical for maintaining and troubleshooting the Video-Agents-Foundry-Solution, which spans AKS clusters, Azure Arc, GPU workloads, and AI agents.

## Application Insights

If Application Insights is deployed with your solution, it provides application performance monitoring, logging, and telemetry.

### Enabling Application Insights

Application Insights can be enabled during deployment. Check the [deployment customization guide](deploy_customization.md) for configuration options.

### Viewing Logs

1. Navigate to the [Azure Portal](https://portal.azure.com/)
2. Open your resource group (named `rg-<environment-name>`)
3. Select your **Application Insights** resource
4. Use **Logs** to run KQL queries against your telemetry data

## Kubernetes Monitoring

### Pod Health Dashboard

After deployment, the `postup` hook runs an automated health check dashboard that shows:
- Running pod counts vs. total pod counts per namespace
- Pass/fail/warn status for each namespace
- Overall deployment health summary

Key namespaces monitored:
- `gpu-operator` - NVIDIA GPU Operator
- `video-indexer` - Video Indexer Arc Extension
- `app-routing-system` - AKS application routing
- `azure-arc` - Azure Arc agents
- `cert-manager` - TLS certificate management

### Manual Health Checks

Check pod status across all namespaces:

```shell
kubectl get pods --all-namespaces
```

Check GPU node status:

```shell
kubectl get nodes -l accelerator=nvidia
kubectl describe node <gpu-node-name>
```

Check Video Indexer extension status:

```shell
kubectl get pods -n video-indexer
kubectl logs -n video-indexer <pod-name>
```

### Azure Monitor for Containers

AKS integrates with Azure Monitor for container insights:

1. Navigate to your AKS cluster in the [Azure Portal](https://portal.azure.com/)
2. Select **Monitoring** > **Insights**
3. View cluster, node, and pod-level metrics

## AI Agent Tracing

If you deployed the AI Foundry project, you can monitor AI agent performance:

### Microsoft Foundry Portal

1. Go to the [Microsoft Foundry Portal](https://ai.azure.com/)
2. Select your project
3. Navigate to the **Tracing** tab to view agent execution traces
4. Monitor token usage, response times, and error rates

### Enable Azure Monitor Tracing

To send agent traces to Azure Monitor:

```shell
azd env set ENABLE_AZURE_MONITOR_TRACING true
```

## Log Analytics

If Log Analytics workspace is deployed, you can query logs across all resources:

1. Navigate to your **Log Analytics workspace** in the Azure Portal
2. Use **Logs** to write KQL queries
3. Common queries:

```kusto
// Container logs from Video Indexer namespace
ContainerLogV2
| where PodNamespace == "video-indexer"
| where TimeGenerated > ago(1h)
| order by TimeGenerated desc

// GPU node performance
Perf
| where ObjectName == "K8SNode"
| where TimeGenerated > ago(1h)
| summarize avg(CounterValue) by CounterName, Computer, bin(TimeGenerated, 5m)
```

## Troubleshooting with Observability

For common issues and their solutions, see the [troubleshooting guide](troubleshooting.md).
