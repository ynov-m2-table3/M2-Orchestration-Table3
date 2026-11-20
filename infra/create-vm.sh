#!/bin/bash
# À lancer UNE fois dans Azure Cloud Shell.
# Crée la VM k3s dans le même réseau que DockerV2 (pour joindre Vault en privé).
set -eu

RG=TP-Orchestration-Table3
LOC=norwayeast
VM=k3s-1

# clé publique de la CI (la même que sur DockerV2 : /home/deploy/.ssh/authorized_keys)
CI_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKO8a6WNMjxKnfmkwLxzz/RfDnqF67HO79cf9tmZI17r deploy@DockerV2"
# ta clé publique perso (pour te connecter en azureuser)
MY_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4xIZOTY0FPlMlEZn4B8pfn031ZJC4RkKA4lagCKq0G mathias.bredeville@ynov.com"

# sous-réseau de DockerV2
NIC=$(az vm show -g $RG -n DockerV2 --query "networkProfile.networkInterfaces[0].id" -o tsv)
SUBNET=$(az network nic show --ids "$NIC" --query "ipConfigurations[0].subnet.id" -o tsv)

az network nsg create -g $RG -l $LOC -n $VM-nsg
az network nsg rule create -g $RG --nsg-name $VM-nsg -n ssh --priority 100 \
  --destination-port-ranges 22 --protocol Tcp --access Allow
az network nsg rule create -g $RG --nsg-name $VM-nsg -n web --priority 110 \
  --destination-port-ranges 80 443 --protocol Tcp --access Allow

az vm create -g $RG -l $LOC -n $VM --zone 1 \
  --image Debian:debian-13:13-gen2:latest --size Standard_B2as_v2 --os-disk-size-gb 64 \
  --subnet "$SUBNET" --nsg $VM-nsg --public-ip-sku Standard \
  --admin-username azureuser --ssh-key-values "$MY_PUBKEY"

# utilisateur deploy pour la CI (sudo car c'est lui qui installe k3s)
az vm run-command invoke -g $RG -n $VM --command-id RunShellScript --scripts "
apt-get update && apt-get install -y curl jq rsync
id deploy || adduser --disabled-password --gecos '' deploy
echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy
chmod 440 /etc/sudoers.d/deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
echo '$CI_PUBKEY' > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
"

az vm list-ip-addresses -g $RG -n $VM -o table
