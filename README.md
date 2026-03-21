# Quick Start

## Create an Azure Service Principal

To create an Azure Service Principal, follow the instructions below:

1. Open the Azure CLI from the Azure web console.
2. Run the following commands:
   
   ```bash
   az ad sp create-for-rbac --name "MyApp" --role Contributor --scopes /subscriptions/{subscription-id}
   ``` 
   
   Replace `{subscription-id}` with your Azure Subscription ID.

## Azure CLI

Once you have created your service principal, you can execute further commands in the Azure CLI.

### Steps

1. Open the Azure CLI from the Azure web console.
2. Run the necessary commands as per your requirements.

## Additional Commands

Here you will include any additional commands needed for your specific setup. 

Refer to the official Azure documentation for more commands and detailed instructions on each step.