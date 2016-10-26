#!/bin/bash

set -e

mkdir -p "$CA_BASE"/{certs,csr,crl,newcerts,private}
chmod -R 700 "$CA_BASE"

function ca_init() {
    cat > "$CA_BASE"/openssl.cnf <<-'EOF'
	[ ca ]
	default_ca = CA_default
	[ CA_default ]
	EOF

    cat >> "$CA_BASE"/openssl.cnf <<-EOF
	dir               = $CA_BASE
	EOF

    cat >> "$CA_BASE"/openssl.cnf <<-'EOF'
	certs             = $dir/certs
	crl_dir           = $dir/crl
	new_certs_dir     = $dir/newcerts
	database          = $dir/index.txt
	serial            = $dir/serial
	RANDFILE          = $dir/private/.rand
	private_key       = $dir/private/ca.key.pem
	certificate       = $dir/certs/ca.cert.pem
	crlnumber         = $dir/crlnumber
	crl               = $dir/crl/ca.crl.pem
	crl_extensions    = crl_ext
	default_crl_days  = 30
	default_md        = sha256
	name_opt          = ca_default
	cert_opt          = ca_default
	default_days      = 3750
	preserve          = no
	policy            = ca_policy
	[ ca_policy ]
	commonName              = supplied
	organizationName        = optional
	emailAddress            = optional
	[ req ]
	default_bits        = 2048
	distinguished_name  = req_distinguished_name
	string_mask         = utf8only
	default_md          = sha256
	x509_extensions     = v3_ca
	[ req_distinguished_name ]
	commonName                      = Common Name
	organizationName                = Kubernetes Group
	emailAddress                    = Email Address
	[ v3_ca ]
	subjectKeyIdentifier = hash
	authorityKeyIdentifier = keyid:always,issuer
	basicConstraints = critical, CA:true, pathlen:0
	keyUsage = critical, digitalSignature, cRLSign, keyCertSign
	extendedKeyUsage=serverAuth,clientAuth
	[ usr_cert ]
	basicConstraints = CA:FALSE
	nsCertType = client
	subjectKeyIdentifier = hash
	authorityKeyIdentifier = keyid,issuer
	keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
	extendedKeyUsage = clientAuth
	[ server_cert ]
	basicConstraints = CA:FALSE
	nsCertType = server
	subjectKeyIdentifier = hash
	authorityKeyIdentifier = keyid,issuer:always
	keyUsage = critical, digitalSignature, keyEncipherment
	extendedKeyUsage = serverAuth,clientAuth
	subjectAltName=${ENV::SAN}
	[ crl_ext ]
	authorityKeyIdentifier=keyid:always
	EOF

    rm -f "$CA_BASE"/index.txt ; touch "$CA_BASE"/index.txt
    echo 1000 > "$CA_BASE"/serial
    rm -f "$CA_BASE"/{certs,csr,crl,newcerts,private}/*

    echo CA: making self-signed root
    openssl req \
        -batch \
        -nodes \
        -x509 \
        -sha256 \
        -days 3650 \
        -newkey rsa:2048 \
        -keyout "$CA_BASE"/private/ca.key.pem \
        -out "$CA_BASE"/certs/ca.cert.pem \
        -subj '/CN=k8s-root' &> "$CA_BASE"/ca.log

    printf "CA certificate "
    openssl x509 -in "$CA_BASE"/certs/ca.cert.pem -noout -fingerprint

    cat > "$CA_BASE/adduser.sh" <<-EOF
	#!/bin/bash
	set -e
	CA_BASE="$CA_BASE"
	CN="\$1"
	if [ -e "\$CN" ] ; then
	    echo "Usage: \$0 <username> [<group> ...]"
	    exit 1
	fi
	SUBJ="/CN=\${CN}"
	for GROUP in "\${@:2}" ; do
	    SUBJ+="/O=\$GROUP"
	done
	cd "\$CA_BASE"
        export SAN=""
	openssl genrsa -out private/"\$CN".key.pem 4096
	chmod 400 private/"\$CN".key.pem
	openssl req -config openssl.cnf \
	      -key private/"\$CN".key.pem \
	      -new -nodes -out csr/"\$CN".csr.pem \
	      -subj "\$SUBJ"
	openssl ca -config openssl.cnf -batch \
	      -extensions usr_cert -days 3650 -notext -md sha256 \
	      -in csr/"\$CN".csr.pem \
	      -out certs/"\$CN".cert.pem
	chmod 444 certs/"\$CN".cert.pem
	echo PRIVATE_KEY=private/"\$CN".key.pem
	echo PUBLIC_CERT=certs/"\$CN".cert.pem
	EOF
    chmod a+x "$CA_BASE/adduser.sh"

}

function ca_server() {
    CN="$1"
    SANS=()
    for NAME in "${@:2}" ; do
        SANS+=($NAME)
    done

    function join_by { local IFS="$1"; shift; echo "$*"; }
    export SAN=$( join_by , "${SANS[@]}" )
    echo CA: Creating server certificate for $CN
    openssl genrsa -out "$CA_BASE"/private/"$CN".key.pem 4096 &> "$CA_BASE"/ca.log
    openssl req -config "$CA_BASE"/openssl.cnf \
        -key "$CA_BASE"/private/"$CN".key.pem \
        -new -nodes -out "$CA_BASE"/csr/"$CN".csr.pem \
        -subj "/CN=$CN" &> "$CA_BASE"/ca.log
    openssl ca -config "$CA_BASE"/openssl.cnf -batch \
        -extensions server_cert -days 3650 -notext -md sha256 \
        -in "$CA_BASE"/csr/"$CN".csr.pem \
        -out "$CA_BASE"/certs/"$CN".cert.pem &> "$CA_BASE"/ca.log
    printf "Server $CN "
    openssl x509 -in "$CA_BASE"/certs/"$CN".cert.pem -noout -fingerprint
}

function ca_client() {
    CN="$1"
    echo CA: Creating client certificate for $CN
    openssl genrsa -out "$CA_BASE"/private/"$CN".key.pem 4096 &> "$CA_BASE"/ca.log
    export SAN=""
    openssl req -config "$CA_BASE"/openssl.cnf \
        -key "$CA_BASE"/private/"$CN".key.pem \
        -new -nodes -out "$CA_BASE"/csr/"$CN".csr.pem \
        -subj "/CN=$CN" &> "$CA_BASE"/ca.log
    openssl ca -config "$CA_BASE"/openssl.cnf -batch \
        -extensions usr_cert -days 3650 -notext -md sha256 \
        -in "$CA_BASE"/csr/"$CN".csr.pem \
        -out "$CA_BASE"/certs/"$CN".cert.pem &> "$CA_BASE"/ca.log
    printf "Client $CN "
    openssl x509 -in "$CA_BASE"/certs/"$CN".cert.pem -noout -fingerprint
}

if false ; then

# 2. Create API server certificate

export SAN=DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:$public_dns,IP:$private_ipv4,IP:$public_ipv4
CN=apiserver
CN=admin

fi
