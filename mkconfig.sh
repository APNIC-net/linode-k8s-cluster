#!/bin/bash

# Configuration block
DATACENTER_ID=3                                  # Fremont, CA
CLUSTER_NAME=${DATACENTER_ID}_linode             # Or whatever you like
MASTER_PLAN=2                                    # Linode4096, 2 cores, 4G RAM, 3TB transfer, 48GB disk
MINION_PLAN=6                                    # Linode12288, 6 cores, 12G RAM, 8TB transfer, 192GB disk
NODE_COUNT=3                                     # One master, three minions
PUBLIC_DNS=kube.example.com                      # Public DNS label for API server
API_TOKEN=$( security find-internet-password -s api.linode.com -w )

# http://despicableme.wikia.com/wiki/Category:Minions
MINION_NAMES=( bob kevin stuart dave jerry mel carl phil henry tom ken mike eric norbert john lance mark chris )

set -e

mkdir -p cluster
export CA_BASE="$PWD/cluster/ca"

# If there are cluster settings, use them
if [ -f cluster/settings.env ] ; then
    . cluster/settings.env
fi

source lib/linode_api.sh
source lib/kubes_ca.sh

# See: http://mywiki.wooledge.org/BashFAQ/026
shuffle() {
    local i tmp size max rand
    size=${#MINION_NAMES[*]}
    for ((i=size-1; i>0; i--)); do
        max=$(( 32768 / (i+1)*(i+1) ))
        while (( (rand=$RANDOM) >= max )); do :; done
        rand=$(( rand % (i+1) ))
        tmp=${MINION_NAMES[i]} MINION_NAMES[i]=${MINION_NAMES[rand]} MINION_NAMES[rand]=$tmp
    done
}
shuffle

cd cluster

# Generate a fresh SSH key for the installer
rm -f install-ssh-key install-ssh-key.pub
ssh-keygen -q -t ed25519 -f install-ssh-key -N '' -C 'bootstrap'

# Generate an SSH key for CoreOS, if one does not exist
if [ ! -f coreos-ssh-key.pub ] ; then
    ssh-keygen -q -t ed25519 -f coreos-ssh-key -N '' -C 'admin'
fi

# Create the CA if it's not already there
if [ ! -f ca/certs/ca.cert.pem ] ; then
    echo Building certificate authority
    ca_init
fi

# Create an admin user certificate if missing
if [ ! -f ca/certs/admin.cert.pem ] ; then
    ca_client admin
fi

CA_CERTIFICATE=$( base64 < ca/certs/ca.cert.pem )

# Look for existing stack script
if [ -f ../.stack-script-id ] ; then
    SCRIPT_ID=$( cat ../.stack-script-id )
    # Attempt to udpate it
    if ! ERROR=$(api_call stackscript.update StackScriptID="${SCRIPT_ID}" script@../install-kubes.script) ; then
        api_call stackscript.create DistributionIDList=140 \
            Label=Install\ Kubernetes \
            isPublic=false \
            script@../install-kubes.script
        SCRIPT_ID=$( jqo .DATA.StackScriptID )
        echo "$SCRIPT_ID" > ../.stack-script-id
        echo "Created new StackScript #$SCRIPT_ID"
    else
        echo "Updated existing StackScript #$SCRIPT_ID"
    fi
fi

# Create all nodes
api_call linode.create DatacenterID=$DATACENTER_ID PlanID=$MASTER_PLAN
MASTER_ID=$( jqo .DATA.LinodeID )
api_call linode.update LinodeID=$MASTER_ID Label="${CLUSTER_NAME}_master_gru" lpm_displayGroup="Kubernetes Cluster"
echo "[$MASTER_ID] master gru created with plan $MASTER_PLAN"
eval NAME_$MASTER_ID=${CLUSTER_NAME}_gru
MINION_IDS=()
for minion in `seq $NODE_COUNT` ; do
    api_call linode.create DatacenterID=$DATACENTER_ID PlanID=$MINION_PLAN
    MINION_ID=$( jqo .DATA.LinodeID )
    MINION_IDS+=( $MINION_ID )
    MINION_NAME=${MINION_NAMES[$minion]}
    eval NAME_$MINION_ID=$MINION_NAME
    api_call linode.update LinodeID=$MINION_ID Label="${CLUSTER_NAME}_minion_$MINION_NAME" lpm_displayGroup="Kubernetes Cluster"
    echo "[$MINION_ID] minion ${CLUSTER_NAME}_minion_$MINION_NAME created with plan $MINION_PLAN"
done

for NODE in $MASTER_ID ${MINION_IDS[@]} ; do
    api_call linode.ip.addprivate LinodeID=$NODE
    api_call linode.ip.list LinodeID=$NODE
    eval $( echo "$OUTPUT" \
        | jq -Mje ".DATA[] | if .ISPUBLIC==1 then \"PUBLIC_$NODE=\", .IPADDRESS else \"PRIVATE_$NODE=\", .IPADDRESS, \"\\nHOSTNAME_$NODE=\", .RDNS_NAME end, \"\\n\"" )
    eval echo "[$NODE] PUBLIC_$NODE=\$PUBLIC_$NODE PRIVATE_$NODE=\$PRIVATE_$NODE HOSTNAME_$NODE=\$HOSTNAME_$NODE"
done

# Add CoreOS disk
for NODE in $MASTER_ID ${MINION_IDS[@]} ; do
    api_call linode.disk.create LinodeID=$NODE Label="CoreOS" Type=raw Size=8000
    eval DISK_$NODE=$( jqo .DATA.DiskID )
    eval echo "[$NODE] created CoreOS disk \$DISK_$NODE"
done

# Create node server certificates for each node
for NODE in $MASTER_ID ${MINION_IDS[@]} ; do
    if [ "$NODE" == "$MASTER_ID" ] ; then
        SAN="DNS:kubernetes DNS:kubernetes.default DNS:kubernetes.default.svc.cluster.local DNS:$PUBLIC_DNS IP:10.2.0.1"
    else
        SAN=
    fi
    eval ca_server linode$NODE $SAN IP:\$PUBLIC_$NODE IP:\$PRIVATE_$NODE
done

SSH_PUB="$( cat coreos-ssh-key.pub )"

# Convenient access to master IP addresses
MASTER_PUBLIC=$( eval echo \$PUBLIC_$MASTER_ID )
MASTER_PRIVATE=$( eval echo \$PRIVATE_$MASTER_ID )
MASTER_HOSTNAME=$( eval echo \$HOSTNAME_$MASTER_ID )

SIZE=$(( $NODE_COUNT + 1 ))
ETCD2_TOKEN=$( curl -s -L http://discovery.etcd.io/new?size=$SIZE )
ETCD2_TOKEN=${ETCD2_TOKEN##*/}
echo etcd2 cluster token: $ETCD2_TOKEN

# This can be safely shared across all nodes, it's temporary
ROOT_PASSWORD="$( apg -M SNCL -m 10 -n 1 )"
echo Installer root password: $ROOT_PASSWORD

# Set up the master
MASTER_CERT=$( base64 < ca/certs/linode$MASTER_ID.cert.pem )
MASTER_KEY=$( base64 < ca/private/linode$MASTER_ID.key.pem )

function install_core() {
    LINODE_ID=$1
    UDF="$2"

    eval DISK_ID=\$DISK_$LINODE_ID
    eval PUBLIC_IP=\$PUBLIC_$LINODE_ID

    # Create the install OS disk from script
    api_call linode.disk.createfromstackscript LinodeID=$LINODE_ID StackScriptID=$SCRIPT_ID \
        DistributionID=140 Label=Installer Size=8000 rootSSHKey="$( cat install-ssh-key.pub )" \
        StackScriptUDFResponses="$UDF" rootPass="$ROOT_PASSWORD"
    INSTALL_DISK_ID=$( jqo .DATA.DiskID )
    echo "[$LINODE_ID] created install disk $INSTALL_DISK_ID"

    # Configure the installer to boot
    api_call linode.config.create LinodeID=$LINODE_ID KernelID=138 Label="Installer" \
        DiskList=$DISK_ID,$INSTALL_DISK_ID RootDeviceNum=2
    CONFIG_ID=$( jqo .DATA.ConfigID )
    echo "[$LINODE_ID] created boot configuration $CONFIG_ID"
    api_call linode.boot LinodeID=$LINODE_ID ConfigID=$CONFIG_ID

    wait_jobs $LINODE_ID

    # Alter the config to boot CoreOS
    api_call linode.config.update LinodeID=$LINODE_ID ConfigID=$CONFIG_ID Label="CoreOS/Kubernetes" \
        DiskList=$DISK_ID KernelID=213 RootDeviceNum=1

    echo "[$LINODE_ID] waiting for CoreOS boot"
    while ! nc -z $PUBLIC_IP 20535 ; do
        sleep 10
    done
    echo "[$LINODE_ID] booted and ready"

    api_call linode.disk.delete LinodeID=$LINODE_ID DiskID=$INSTALL_DISK_ID
}

UDF=$( cat <<-EOF
	{
	    "cluster_ca_cert": "$CA_CERTIFICATE",
	    "minion_cert": "$MASTER_CERT",
	    "minion_key": "$MASTER_KEY",
	    "ssh_key": "$SSH_PUB",
	    "public_ip": "$MASTER_PUBLIC",
	    "private_ip": "$MASTER_PRIVATE",
	    "private_dns": "$MASTER_HOSTNAME",
	    "master_ip": "$MASTER_PRIVATE",
	    "etcd2_token": "$ETCD2_TOKEN",
	    "node_type": "master",
	    "node_name": "master"
	}
	EOF
)

echo "[$MASTER_ID] building gru as the master"
install_core $MASTER_ID "$UDF" &

for NODE_ID in ${MINION_IDS[@]} ; do
    MINION_CERT=$( base64 < ca/certs/linode$NODE_ID.cert.pem )
    MINION_KEY=$( base64 < ca/private/linode$NODE_ID.key.pem )
    MINION_PUBLIC=$( eval echo \$PUBLIC_$NODE_ID )
    MINION_PRIVATE=$( eval echo \$PRIVATE_$NODE_ID )
    MINION_HOSTNAME=$( eval echo \$HOSTNAME_$NODE_ID )
    MINION_NAME=$( eval echo \$NAME_$NODE_ID )
    UDF=$( cat <<-EOF
	    {
	        "cluster_ca_cert": "$CA_CERTIFICATE",
	        "minion_cert": "$MINION_CERT",
	        "minion_key": "$MINION_KEY",
	        "ssh_key": "$SSH_PUB",
	        "public_ip": "$MINION_PUBLIC",
	        "private_ip": "$MINION_PRIVATE",
	        "private_dns": "$MINION_HOSTNAME",
	        "master_ip": "$MASTER_PRIVATE",
	        "etcd2_token": "$ETCD2_TOKEN",
	        "node_type": "minion",
	        "node_name": "$MINION_NAME"
	    }
	EOF
    )
    echo "[$NODE_ID] building $MINION_NAME as a minion"
    install_core $NODE_ID "$UDF" &
done

wait

echo Construcing cluster/kubeconfig...
kubectl config set-cluster $CLUSTER_NAME \
        --kubeconfig=kubeconfig \
        --certificate-authority=ca/certs/ca.cert.pem \
        --embed-certs=true \
        --server=https://$MASTER_PUBLIC:6443/
kubectl config set-credentials $CLUSTER_NAME-admin \
        --kubeconfig=kubeconfig \
        --client-certificate=ca/certs/admin.cert.pem \
        --client-key=ca/private/admin.key.pem \
        --embed-certs=true
kubectl config set-context default \
        --kubeconfig=kubeconfig \
        --cluster=$CLUSTER_NAME \
        --user=$CLUSTER_NAME-admin
kubectl config use-context default --kubeconfig=kubeconfig

echo "[$MASTER_ID"] Master gru now online at $MASTER_PUBLIC
for NODE_ID in ${MINION_IDS[@]} ; do
    MINION_PUBLIC=$( eval echo \$PUBLIC_$NODE_ID )
    MINION_NAME=$( eval echo \$NAME_$NODE_ID )
    echo "[$NODE_ID] Minion $MINION_NAME now online at $MINION_PUBLIC"
done

echo "Waiting for Kubernetes API server to start"
while ! nc -z $MASTER_PUBLIC 6443 ; do
    sleep 10
done

kubectl --kubeconfig=kubeconfig cluster-info
kubectl --kubeconfig=kubeconfig get nodes

kubectl --kubeconfig=kubeconfig create -f ../pods

echo '# SSH configuration for k8s cluster '$CLUSTER_NAME > ssh-config
idfile="$(pwd)/coreos-ssh-key"
for NODE in $MASTER_ID ${MINION_IDS[@]} ; do
    eval echo "Host \$NAME_$NODE" >> ssh-config
    eval echo "    Hostname \$PUBLIC_$NODE" >> ssh-config
done
names="gru "
for NODE in ${MINION_IDS[@]} ; do
    names=$( eval echo "$names \$NAME_$NODE" )
done
cat >> ssh-config <<-EOF
	Host $names
	  Port 20535
	  User core
	  IdentitiesOnly yes
	  IdentityFile "$idfile"
EOF
