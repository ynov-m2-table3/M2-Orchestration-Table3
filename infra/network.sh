#!/bin/bash
# À lancer UNE fois dans Azure Cloud Shell.
# Crée un réseau en Suède et un en Pologne, et relie les 3 régions entre elles (peering).
set -eu

RG=TP-Orchestration-Table3

# réseau de Norvège : celui de DockerV2 et k3s-1
NIC=$(az vm show -g $RG -n DockerV2 --query "networkProfile.networkInterfaces[0].id" -o tsv)
SUBNET=$(az network nic show --ids "$NIC" --query "ipConfigurations[0].subnet.id" -o tsv)
VNET_NO=${SUBNET%/subnets/*}
echo "Norvège : $(az network vnet show --ids "$VNET_NO" --query "addressSpace.addressPrefixes" -o tsv)"

# plages qui ne chevauchent ni la Norvège (172.16), ni Docker (172.17 à 172.20), ni k3s (10.42 et 10.43)
az network vnet create -g $RG -l swedencentral -n vnet-sweden \
  --address-prefix 10.10.0.0/16 --subnet-name nodes --subnet-prefix 10.10.1.0/24 -o none
az network vnet create -g $RG -l polandcentral -n vnet-poland \
  --address-prefix 10.11.0.0/16 --subnet-name nodes --subnet-prefix 10.11.1.0/24 -o none

VNET_SE=$(az network vnet show -g $RG -n vnet-sweden --query id -o tsv)
VNET_PL=$(az network vnet show -g $RG -n vnet-poland --query id -o tsv)

# un peering se crée dans chaque sens
peer() {
  az network vnet peering create -o none \
    -g "$(echo "$1" | cut -d/ -f5)" --vnet-name "$(basename "$1")" \
    -n "vers-$(basename "$2")" --remote-vnet "$2" --allow-vnet-access
}
peer "$VNET_NO" "$VNET_SE"; peer "$VNET_SE" "$VNET_NO"
peer "$VNET_NO" "$VNET_PL"; peer "$VNET_PL" "$VNET_NO"
peer "$VNET_SE" "$VNET_PL"; peer "$VNET_PL" "$VNET_SE"

az network vnet peering list -g $RG --vnet-name vnet-sweden --query "[].{nom:name, etat:peeringState}" -o table
az network vnet peering list -g $RG --vnet-name vnet-poland --query "[].{nom:name, etat:peeringState}" -o table
