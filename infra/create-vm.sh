#!/bin/bash
# bash create-vm.sh <nom> <région> <zone> [taille]
#   ex : bash create-vm.sh k3s-2 swedencentral 1
# Taille par défaut : B2als_v2 (2 vCPU, 4 Go), suffisant pour un master (k3s-1 et DockerV2 restent en 8 Go).
# Crée une VM Debian dans le réseau de sa région (voir network.sh), avec l'utilisateur deploy pour la CI.
set -eu

RG=TP-Orchestration-Table3
VM=${1:?nom de la VM}
LOC=${2:-norwayeast}
SIZE=${3:-Standard_B2als_v2}
ZONE=${4:-}

# clé publique de la CI (la même que sur DockerV2 : /home/deploy/.ssh/authorized_keys)
CI_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKO8a6WNMjxKnfmkwLxzz/RfDnqF67HO79cf9tmZI17r deploy@DockerV2"
# ta clé publique perso (pour te connecter en azureuser)
MY_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4xIZOTY0FPlMlEZn4B8pfn031ZJC4RkKA4lagCKq0G mathias.bredeville@ynov.com"

case $LOC in
  norwayeast)
    NIC=$(az vm show -g $RG -n DockerV2 --query "networkProfile.networkInterfaces[0].id" -o tsv)
    SUBNET=$(az network nic show --ids "$NIC" --query "ipConfigurations[0].subnet.id" -o tsv) ;;
  swedencentral)
    SUBNET=$(az network vnet subnet show -g $RG --vnet-name vnet-sweden -n nodes --query id -o tsv) ;;
  polandcentral)
    SUBNET=$(az network vnet subnet show -g $RG --vnet-name vnet-poland -n nodes --query id -o tsv) ;;
  *) echo "région non prévue : $LOC"; exit 1 ;;
esac

az network nsg create -g $RG -l $LOC -n $VM-nsg -o none
az network nsg rule create -g $RG --nsg-name $VM-nsg -n ssh --priority 100 \
  --destination-port-ranges 22 --protocol Tcp --access Allow -o none
az network nsg rule create -g $RG --nsg-name $VM-nsg -n web --priority 110 \
  --destination-port-ranges 80 443 --protocol Tcp --access Allow -o none

az vm create -g $RG -l $LOC -n $VM ${ZONE:+--zone $ZONE} \
  --image Debian:debian-13:13-gen2:latest --size $SIZE \
  --os-disk-size-gb 64 --storage-sku StandardSSD_LRS \
  --subnet "$SUBNET" --nsg $VM-nsg --public-ip-sku Standard \
  --admin-username azureuser --ssh-key-values "$MY_PUBKEY" -o none

# utilisateur deploy pour la CI (sudo car c'est lui qui installe k3s)
az vm run-command invoke -g $RG -n $VM --command-id RunShellScript -o none --scripts "
apt-get update && apt-get install -y curl jq rsync
id deploy || adduser --disabled-password --gecos '' deploy
echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy
chmod 440 /etc/sudoers.d/deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
echo '$CI_PUBKEY' > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
"

# extinction automatique tous les soirs à 19h (heure de Paris), pour ne pas brûler le crédit
az vm auto-shutdown -g $RG -n $VM --time 1800 --location $LOC -o none \
  || echo "extinction automatique non disponible en $LOC : penser à éteindre $VM à la main"

az vm list-ip-addresses -g $RG -n $VM -o table
