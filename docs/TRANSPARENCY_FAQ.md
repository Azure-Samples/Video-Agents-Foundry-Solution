# Transparency FAQ - Video-Agents-Foundry-Solution

## What is the Video-Agents-Foundry-Solution?

The Video-Agents-Foundry-Solution is an Azure solution accelerator that deploys an end-to-end framework for AI-powered video analysis at the edge. It uses Azure Video Indexer enabled by Azure Arc, combined with intelligent AI agents built on Azure OpenAI, for automated decision-making and real-time video insights.

## What can the Video-Agents-Foundry-Solution do?

- Process and analyze live and recorded video streams at the edge
- Extract multimodal AI insights including speech transcription, face detection, object tracking, scene detection, and action recognition
- Leverage AI agents to automate complex video analysis workflows
- Enable real-time decision-making with low latency and full data sovereignty

## What is the intended use of the Video-Agents-Foundry-Solution?

This solution is intended as a proof of concept and starting point for organizations looking to deploy AI-powered video analysis at the edge. Target scenarios include:

- **Retail Analytics** - Foot traffic analysis, shelf interaction, queue monitoring
- **Manufacturing Quality Control** - Automated defect detection and quality monitoring
- **Safety & Compliance Monitoring** - PPE detection, unauthorized access, hazard identification
- **Smart City & Traffic Management** - Real-time traffic flow, incident detection, pedestrian safety

## How was the Video-Agents-Foundry-Solution evaluated?

This solution uses Azure AI services that have been evaluated for responsible AI considerations:

- **Azure Video Indexer** follows Microsoft's Responsible AI principles. See [Azure Video Indexer transparency notes](https://learn.microsoft.com/azure/azure-video-indexer/transparency-note).
- **Azure OpenAI Service** is subject to Microsoft's responsible AI guidelines. See [Azure OpenAI transparency note](https://learn.microsoft.com/legal/cognitive-services/openai/transparency-note).
- **Azure AI Foundry Agent Service** provides transparency documentation. See [Agent Service transparency note](https://learn.microsoft.com/azure/ai-foundry/responsible-ai/agents/transparency-note).

## What are the limitations of the Video-Agents-Foundry-Solution?

- **Language support** - This solution currently supports English language input and output only
- **AI accuracy** - AI-generated insights may contain inaccuracies and should not be used as the sole basis for critical decisions
- **Not a medical device** - This solution is not designed or intended for use as a medical device
- **Not for high-risk use** - This solution should not be used in scenarios where service interruption could result in death, serious bodily injury, or environmental damage
- **Proof of concept** - This is intended as a starting point and is not a finished, production-ready product

## What operational factors and settings allow for effective and responsible use?

- **Data sovereignty** - Video data is processed at the edge, ensuring compliance with data residency requirements
- **Access control** - Azure RBAC and Managed Identity are used for secure resource access
- **Monitoring** - Application Insights and Log Analytics provide observability into system behavior
- **Human oversight** - AI agent outputs should be reviewed by qualified personnel before acting on critical decisions

## Learn more

- [Azure AI Foundry Responsible AI](https://learn.microsoft.com/azure/ai-foundry/responsible-ai/)
- [Microsoft Responsible AI Principles](https://www.microsoft.com/ai/responsible-ai)
- [Agent Service Transparency Note](https://learn.microsoft.com/azure/ai-foundry/responsible-ai/agents/transparency-note)
- [Agent Framework Transparency FAQ](https://github.com/microsoft/agent-framework/blob/main/TRANSPARENCY_FAQ.md)
- [Azure Video Indexer Transparency Note](https://learn.microsoft.com/azure/azure-video-indexer/transparency-note)
