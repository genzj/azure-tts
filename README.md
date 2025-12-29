# Azure TTS Service Recreation Service

Automates the recreation of Azure Text-to-Speech (TTS) services to bypass free tier quota limitations.

## Overview

Azure's free TTS service has usage quotas that, once exceeded, prevent further text-to-speech operations. This script automates the process of:

1. Deleting existing TTS service instances
2. Purging soft-deleted services to free up namespace
3. Recreating fresh TTS services
4. Retrieving API keys for the new services and publish it via a Telegarm Bot

## Prerequisites

- Azure CLI installed and configured
- Azure service principal with appropriate permissions (see next section)
- Resource group "TTS" in your Azure subscription
- Template spec "data/audio-book-tts.json" uploaded in the resource group

### Required Azure Service Principal

Your service principal needs the following permissions:

- Create by following https://learn.microsoft.com/en-us/cli/azure/azure-cli-sp-tutorial-1?view=azure-cli-latest&tabs=bash#create-a-service-principal-using-variables
- Scope is the target subscription
- With roles (TBD, if not working, use `Owner`):
  - `Cognitive Services Contributor` role on the TTS resource group
  - `Template Spec Reader` role for deployment operations
  - `Resource Group Reader` role for validation

## Installation

1. Clone this repository:

```bash
git clone https://github.com/genzj/azure-tts.git
cd azure-tts
```

2. Copy the environment template:

```bash
cp .env.sample .env
```

3. Configure your Azure credentials in `.env`:

4. Create your deployment parameters:

```bash
cp ./data/deployment-input-sample.json deployment-input.json
```

5. Edit `deployment-input.json` with your specific parameters.

## Usage

### Basic Usage

Run the complete recreation process:

```bash
./tts-recreate.sh
```

## Error Codes

| Code | Description                         |
| ---- | ----------------------------------- |
| 1    | Azure login failed                  |
| 2    | Resource group "TTS" not found      |
| 3    | Template "audio-book-tts" not found |

## Troubleshooting

### Common Issues

**Login Failures**

- Verify service principal credentials in `.env`
- Ensure service principal has not expired
- Check tenant ID is correct

**Resource Not Found**

- Confirm resource group "TTS" exists in your subscription
- Verify template spec "audio-book-tts" is deployed
- Check your service principal has read access

**Deployment Failures**

- Validate `deployment-input.json` parameters
- Ensure template spec version is accessible
- Check resource quotas in your subscription

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Security

- Never commit `.env` files containing credentials
- Use Azure Key Vault for production deployments
- Regularly rotate service principal secrets
- Follow principle of least privilege for permissions

## Support

For issues and questions:

- Check the [troubleshooting section](#troubleshooting)
- Review Azure CLI documentation
- Open an issue in this repository

## Acknowledgments

- Azure CLI team for comprehensive tooling
- Azure Cognitive Services documentation
