#!/bin/bash

# Update .NET workloads
sudo dotnet workload update

# Install SWA CLI
npm install --global @azure/static-web-apps-cli

# Install Azure Functions Core Tools
npm install --global azure-functions-core-tools@4 --unsafe-perm true

# Install emulator certificate
curl -k https://cosmos-db:8081/_explorer/emulator.pem > ~/emulatorcert.crt
sudo cp ~/emulatorcert.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates