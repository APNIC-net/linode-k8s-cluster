## Installing Kubernetes on Linode

The `mkconfig.sh` script will create a Kubernetes cluster on Linode, running on
CoreOS.  The default settings create one (small-ish) master node and three
(moderate) operational nodes.

Configuration is achieved either by creating a `cluster/settings.env` file
overriding the variables at the top of the script, or by modifying the script
directly.

### What's in the box

The script will create a master node, by default on a small Linode instance, and
a set of minions, by default on moderate Linode instances.  The master node will
run a publicly visible API server on port 6443, secured with x.509 certificates
for both the server and users of the server.

The nodes will participate in an `etcd2` cluster, with peer communications also
secured using x.509 certificates, over the Linode private IPv4 network.

The networking layer is provded by `flanneld`, operating by default in
10.1.0.0/16 for pods, with each node assigned a /22, and 10.2.0.0/16 for
services.

A `kubedns` service is installed, and a dashboard component is configured,
which will be available on the master node's public IP address at `/ui`, and
will require the administrator's x.509 certificate and cluster CA certificate
to be installed in your browser to access.

The nodes are secured with an SSH key, which by default will be generated during
the script's execution, but which may instead be a copy of an existing user key.
As they're CoreOS, you can log into them as the `core` user, which has complete
`sudo` access on each node.  Don't let the SSH key escape!  The generated key
has no passphrase, so it's better if you provide your own.

### What's not in the box

The installed systems will not have a fine-grained Kubernetes authentication
mechanism enabled.  With the certificate authority created by the script, you
can easily create new user certificates, and assign users to groups, but you
must decide how you want to inform Kubernetes of users, groups, and access
control, and set that up yourself.

### Known issues

Before the `etcd2` cluster has initialised itself, the `flanneld` service will
fail because it cannot connect to the local service, and the `docker` service
will nevertheless start itself, yet bind to the wrong address pool.  I have not
yet determined why `docker` starts when `flanneld` is a prerequisite, but for
now you must log into each node and `systemctl restart docker` to correct it.
This is only a problem on the initial boot after setup, while `etcd2` is
obtaining quorum for its cluster.

Communication from the API server to the minions is faulty.  Kubernetes expects
that the minion names are internally resolvable DNS labels.  Kubernetes also
does not secure API server to minion communication effectively - while minions
have self-signed certificates, the server trusts any certificate and the minion
doesn't verify it's the "real" server talking to it.  By default, these scripts
will boot up a cluster which allows communication between nodes ONLY over the
flannel network.  It should also automatically insert `iptables` rules to permit
the other private IPs of the cluster to reach each kubelet service.  There
should also be a rule to permit anything from the `docker0` interface to allow
pods to communicate with their kubelet by name.

The cloud-init boot mechanism overwrites the service account secret key each
master boot, which causes all kinds of chaos.  The only current workaround is to
delete all secrets and restart all nodes.  The ideal solution is likely to be
using Ignition rather than cloud-init to set up the machines.

The kubelet will need to be run using kubelet-wrapper, rather than as-is, to
allow `kubectl port-forward` to work.  There is no `socat` installed on base
CoreOS.  Because of this, all the file locations need to change to suit the
predetermined paths chosen by Core, or an alternative kubelet-wrapper script
will be needed, which is less preferable.

It is probable that at least the master must run `dnsmasq` with each of the
nodes named in `/etc/hosts` to allow cross-node communications to happen despite
the broken assumption of kubernetes that node names are fully resolvable in the
DNS.

### Default settings

```bash
CLUSTER_NAME=linode           # A largely internal matter, but marks the minion-names uniquely in linode flat namespace
DATACENTER_ID=3               # Fremont, CA
MASTER_PLAN=2                 # Linode4096
MINION_PLAN=6                 # Linode12288
NODE_COUNT=3                  # One master, three minions
PUBLIC_DNS=kube.example.com   # Public DNS label for API server
# The Linode API token, by default read from the OS X keychain
API_TOKEN=$( security find-internet-password -s api.linode.com -w )
```

### Pre-install

#### get an API key, get a good one.

I strongly recommend that you create a fresh [API key] for this procedure, with
the minimum possible age limit.  As Linode API keys give full access to the
owner's account, they are potentially dangerous, and it's more fun to create
fresh API keys every time you need to tweak and re-run the script than it is to
deal with runaway costs if someone compromises your Linode account.

#### Where can you play? your api key can tell you

```curl -s "https://api.linode.com/?api_key=$( security find-internet-password -s api.linode.com -w )&api_action=avail.datacenters" | jq```

will fetch a nice list of the _current_ datacenters, so you can find the index value to use in ```DATACENTER_ID``` above

### The install procedure

 1. Crypto material is prepared.

     a. A temporary SSH key for installation is made.

        This key has no use once installation has completed.

     b. An SSH key for CoreOS node maintenance is made.

        An existing public key will be used if present as `cluster/coreos-ssh-key.pub`.

     c. A certificate authority is created for cluster security.

        The CA is self-signed; the root private key is never sent off-site.  If
        a CA is already present, it will not be overwritten.  For more secure
        setups, the CA may be a child of another CA, the root key may be
        protected with a password, or the root key may even be destroyed once
        the cluster is set up, at the cost of a more complex process for
        creating new users or nodes.

     d. An administrator user certificate is created.

        If an `admin` certificate exists, it will be used rather than a new one
        generated.

 2. Kubernetes nodes are installed on Linode.

    This step requires an [API key] to be created.

     a. A Linode [StackScript] is created to install CoreOS on each node.

        The script ID is cached, and repeated runs will refresh and re-use the
        same script object.

     b. Nodes are created using the API.

        A root disk of 8GB is initialised.  The remaining disk is unassigned,
        and may be used after installation to set up NFS volumes or similar.

     c. Private IPs are assigned.

        Linode private IPv4 addresses are used for intra-cluster communications,
        avoiding external traffic quota consumption.  Note that Linode private
        addresses are visible to other tenants, and so intra-cluster security is
        essential.  All intra-cluster processes are either TLS protected or
        only bound on the overlay network.

     d. Per-node certificates are created.

        These certificates authenticate each node to the API server on the
        master, and authenticate each `etcd2` cluster member with peers.

     e. Nodes are initialised in parallel.

        A temporary install disk is booted with the StackScript.  The script
        installs CoreOS on the primary disk and reboots the node into Core.  If
        any install step fails, the install disk is left intact, and can be
        booted to inspect the CoreOS disk and configuration data.

 3. Final configuration is performed.

     a. A `cluster/kubeconfig` file is created that can be used to administer the cluster.

        The contents of this file can be incorporated into `$HOME/.kube/config`
        if desired.

     b. The DNS and dashboard add-ons are installed using `kubectl`.

     c. A `cluster/ssh-config` file is created to simplify logging into nodes.

        This file may be appended to `$HOME/.ssh/config` if desired.

### Acknowledgements

The minion names are taken at random from the names of minions in the Despicable
Me family of movies.

[StackScript]: https://www.linode.com/stackscripts
[API key]: https://www.linode.com/api
