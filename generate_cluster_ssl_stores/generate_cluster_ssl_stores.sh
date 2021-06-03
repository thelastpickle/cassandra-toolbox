#!/bin/bash

set -e
#
# Generate the Keystores and Truststore to use when SSL encrypting communications between Cassandra nodes. In an
#   SSL handshake, the purpose of a Truststore is to verify credentials and purpose of a Keystore is to provide the
#   credentials. The credentials are derived from the Root Certificate Authority (Root CA).
#
# The Root CA that is generated from the Certificate Authority Configuration file is the core component of SSL
#   encryption. The CA is used to sign other certificates, thus forming a certificate pair with the signed certificate.
#
# The Truststore contains the Root CA, and is used to determine whether the certificate from another party is to be
#   trusted. That is, it is used to verify credentials from a third party. If the certificate from a third party were
#   signed by the Root CA then the remote party can be trusted.
#
# The Keystore contains a certificate generated from the store and signed by the Root CA, and the Root CA used to sign
#   the certificate. The Keystore determines which authentication certificate to send to the remote host and provide
#   those when establishing the connection.
#
usage() {
  cat << EOF
This script generates the Keystores and Truststore to use when SSL encrypting communications between Cassandra nodes.

Usage: $0 [OPTIONS] <CA_CERT_CONFIG_PATH>

Passwords for the Keystore and Truststore must be specified in the following shell environment variables.

TRUSTSTORE_PASSWORD          - The password for the new Truststore.
EXISTING_TRUSTSTORE_PASSWORD - The password of an existing Truststore when using the -t option to populate the existing
                                  store with the new Certificate Authorities generated for the nodes.

Options:
 -g                             Generate passwords for each Keystore and Truststore. The passwords will be written to a
                                .password file along with the corresponding store name. If the TRUSTSTORE_PASSWORD
                                environment variable is set, this option will generate passwords for only each Keystore.

 -c                             Set the Root Certificate Authority creation scope to be per cluster. That is each node
                                has its own keystore, however they all contain the same Root Certificate Authority. By
                                default it is per host. That is, by default each node has its own keystore, and its own
                                unique Root Certificate Authority.

 -n=NODE_LIST                   Comma separated list of nodes defined by NODE_LIST to generate Certificate Authorities
                                and stores for. For example:
                                    127.0.0.1,127.0.0.2,127.0.0.3

                                If unspecified, a single Keystore and Truststore will be generated.

 -p=KEYSTORE_PREFIX             String defined by KEYSTORE_PREFIX that will be used to form the Keystore name. The
                                format of the name is <KEYSTORE_PREFIX>{IP_ADDRESS}<KEYSTORE_SUFFIX>.jks. Defaults to
                                an empty string.

 -s=KEYSTORE_SUFFIX             String defined by KEYSTORE_SUFFIX that will be used to form the Keystore name. The
                                format of the name is <KEYSTORE_PREFIX>{IP_ADDRESS}<KEYSTORE_SUFFIX>.jks. Defaults to
                                an empty string.

 -t=TRUSTSTORE_NAME             String defined by TRUSTSTORE_NAME that will be used to form the truststore name.
                                Defaults to 'cassandra-server-truststore'. In this case final file name will be
                                    cassandra-server-truststore.jks

 -z=KEYSTORE_KEY_SIZE           The size of the Keystore key defined by KEYSTORE_KEY_SIZE in bits. Defaults to 2048.

 -v=VALID_DAYS                  Number of days defined by VALID_DAYS the Root Certificate Authority ill be valid for.
                                Defaults to 365.

 -e=EXISTING_TRUSTSTORE_PATH    Path to an existing Truststore defined by PATH. If specified this Truststore will be
                                populated with the new Certificate Authorities generated for the nodes. This is useful
                                when rotating certificates. The password for the existing Truststore must be set in
                                the following shell environment variable:
                                    EXISTING_TRUSTSTORE_PASSWORD.

 -o=OUTPUT_PATH                 Output directory defined by PATH to place stores and other resources generated.
                                Defaults to './ssl_artifacts_<TIME_STAMP>'

 -h                             Help and usage.
EOF
    exit 2
}

parse_config() {
  local config_section=""
  local distinguished_name_section=""

  while IFS='= ' read -r line || [ -n "$var" ]
  do
    local s_line=$(tr -s ' ' <<<"$line")
    local var=$(cut -d' ' -f1 <<<"${s_line}")
    local val=${s_line/${var}\ /}

    case "${var}" in
      ""|"\n")
        continue
      ;;
      "[")
        config_section=${val/\ ]/}
      ;;
      "distinguished_name")
        distinguished_name_section="${val/=\ /}"
      ;;
      "output_password")
        root_ca_psk_password="${val/=\ /}"
      ;;
      *)
        if [ "${config_section}" = "${distinguished_name_section}" ]
        then
          distinguished_names+=("${var}=${val/=\ /}")
        fi
      ;;
    esac
  done < "$1"
}

generate_password() {
  openssl rand -base64 48 | tr -d '/' | tr -d '=' | tr -d '+' | cut -c 1-32
}

generate_cn_distinguished_name_for_host() {
  local distinguished_names_str=""
  local distinguished_names_len=${#distinguished_names[@]}
  local count_itr=0
  while [ ${count_itr} -lt "${distinguished_names_len}" ]
  do
    local key_val=${distinguished_names[${count_itr}]}
    local key=$(cut -d'=' -f1 <<<"${key_val}")
    local val=${key_val/${key}=/}

    if [ "${key}" = "CN" ]
    then
      val=$1
    fi

    if [ -z "${distinguished_names_str}" ]
    then
      distinguished_names_str="${key}=${val}"
    else
      distinguished_names_str="${distinguished_names_str}, ${key}=${val}"
    fi

    count_itr=$((count_itr + 1))
  done

  echo "${distinguished_names_str}"
}

### Main code ###
time_stamp=$(date +"%Y%m%d_%H%M%S")
generate_passwords=false
node_list=""
keystore_prefix=""
keystore_suffix="-keystore"
truststore_name="common-truststore.jks"
keystore_keysize=2048
root_ca_creation_scope="host"
root_ca_psk_password=""
cert_valid_days=365
distinguished_names=()
existing_truststore_path=""
output_path="./ssl_artifacts_${time_stamp}"

while getopts "gcn:p:s:t:z:v:e:o:h" opt_flag; do
  case $opt_flag in
    g)
      generate_passwords="true"
      ;;
    c)
      root_ca_creation_scope="cluster"
      ;;
    n)
      node_list=$OPTARG
      ;;
    p)
      keystore_prefix=$OPTARG
      ;;
    s)
      keystore_suffix=$OPTARG
      ;;
    t)
      truststore_name=$OPTARG
      ;;
    z)
      keystore_keysize=$OPTARG
      ;;
    v)
      cert_valid_days=$OPTARG
      ;;
    e)
      existing_truststore_path=$OPTARG
      ;;
    o)
      output_path=$OPTARG
      ;;
    h)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

shift $(($OPTIND - 1))

node_array=(cassandra-node)
ca_cert_config_path="$1"

if [ -z "${ca_cert_config_path}" ]
then
  echo "Path to CA Certificate Configuration missing. Please pass this as a positional argument"
  echo ""
  usage
fi

if [ -n "${node_list}" ]
then
  node_array=("$(tr -s ',' ' ' <<< "${node_list}")")
fi

if [ -n "${existing_truststore_path}" ] && [ -z "${EXISTING_TRUSTSTORE_PASSWORD}" ]
then
  echo "Path to the existing Truststore ${existing_truststore_path} has been defined but no password set in environment variable EXISTING_TRUSTSTORE_PASSWORD"
  echo ""
  usage
fi

parse_config "${ca_cert_config_path}"

if [ ${#distinguished_names[@]} -eq 0 ]
then
  cat << EOF
No X.500 Distinguished Name found in Certificate Authority configuration file: $ca_cert_config_path. Please add them to them to the file.
Further information about Distinguished Names can be found in the Java documentation.

  https://docs.oracle.com/javase/8/docs/technotes/tools/unix/keytool.html#CHDHBFGJ
EOF
  exit 2
fi

# Parse node list if supplied and push values into an array.
if [ -n "${node_list}" ]
then
  node_array=("$(tr -s ',' ' ' <<< "${node_list}")")
fi

certs_dir="${output_path}/certs"
stores_dir="${output_path}"

mkdir -p "${stores_dir}"
mkdir -p "${certs_dir}"

echo
echo "Artifacts generated will be placed in: '${output_path}'"

echo
echo "Using Certificate Authority configuration to generate keystores"
cat "${ca_cert_config_path}"

# Check if we need to add an extension to the truststore name
if [ "$(rev <<< "${truststore_name}" | cut -d'.' -f1 | rev)" != 'jks' ]
then
  truststore_name="${truststore_name}.jks"
fi

stores_password_file="${stores_dir}/stores.password"
truststore_password=""
truststore_path="${stores_dir}/${truststore_name}"

if [ -n "${TRUSTSTORE_PASSWORD}" ]
then
  truststore_password="${TRUSTSTORE_PASSWORD}"
fi

if [ -z "${truststore_password}" ]
then
  if [ "${generate_passwords}" = "true" ]
  then
    truststore_password=$(generate_password)
  else
    while [ -z "${truststore_password}" ]
    do
      echo
      read -r -s -p "Please enter a password for the truststore: " ts_in_password
      echo
      if [ -z "${ts_in_password}" ]
      then
        echo "Input is an empty string which is invalid."
      else
        truststore_password="${ts_in_password}"
      fi
    done
  fi
fi

# ca = Certificate Authority
# pc = Public Certificate
# psk = Private Signing Key
root_ca_alias="CARoot_${time_stamp}"
root_ca_name="ca_${time_stamp}"
root_ca_pc_path="${certs_dir}/${root_ca_name}.cert"
root_ca_psk_path="${certs_dir}/${root_ca_name}.key"

create_new_ca_psk="true"
add_ca_to_truststore="true"

for node_i in ${node_array[*]}
do
  echo
  echo "Generate Keystore for node: ${node_i}"

  node_name=$(tr -s '.' '-' <<< "${node_i}")

  node_alias="${node_name}_${time_stamp}"

  # If the CA scope is per host then generate a new CA each loop
  if [ "${root_ca_creation_scope}" = "host" ]
  then
    root_ca_alias="${node_name}_CARoot_${time_stamp}"
    root_ca_pc_path="${certs_dir}/${node_name}_${root_ca_name}.cert"
    root_ca_psk_path="${certs_dir}/${node_name}_${root_ca_name}.key"
  fi

  sign_req_cert_path="${certs_dir}/${node_name}_sign_req_${time_stamp}.cert"
  signed_cert_path="${certs_dir}/${node_name}_signed_${time_stamp}.cert"

  node_keystore_path="${stores_dir}/${keystore_prefix}${node_name}${keystore_suffix}.jks"

  cat << EOF
  - Root Certificate Authority alias:                     $root_ca_alias
  - Root Certificate Authority Public Certificate path:   $root_ca_pc_path
  - Root Certificate Authority Private Signing Key path:  $root_ca_psk_path
  - Keystore path:                                        $node_keystore_path
EOF
  # Create the Root Certificate Authority (Root CA) from the Certificate Authority Configuration and verify contents.
  if [ "${create_new_ca_psk}" = "true" ]
  then
    if [ "${root_ca_creation_scope}" = "cluster" ]
    then
      cat << EOF

Warning:
Root Certificate Authority creation scope set to "cluster" level. Only one Certificate Authority will be created.

EOF
      create_new_ca_psk="false"
    fi

    openssl req \
      -config "${ca_cert_config_path}" \
      -new \
      -x509 \
      -keyout "${root_ca_psk_path}" \
      -out "${root_ca_pc_path}" \
      -days "${cert_valid_days}"
    openssl x509 -in "${root_ca_pc_path}" -text -noout
    echo
  fi

  keystore_password=""
  if [ "${generate_passwords}" = "true" ]
  then
    keystore_password=$(generate_password)
  else
    while [ -z "${keystore_password}" ]
    do
      echo
      read -r -s -p "Please enter a password for the ${node_i} keystore: " ks_in_password
      echo
      if [ -z "${ks_in_password}" ]
      then
        echo "Input is an empty string which is invalid."
      else
        keystore_password="${ks_in_password}"
      fi
    done
  fi

  echo "${keystore_prefix}${node_name}${keystore_suffix}.jks:${keystore_password}" >> "${stores_password_file}"

  distinguished_names_node_str=$(generate_cn_distinguished_name_for_host "${node_alias}")
  echo -e "Distinguished Names for node:\n ${distinguished_names_node_str}"

  # Generate public/private key pair and the key stores.
  keytool \
    -genkeypair \
    -keyalg RSA \
    -alias "${node_alias}" \
    -keystore "${node_keystore_path}" \
    -storepass "${keystore_password}" \
    -keypass "${keystore_password}" \
    -validity "${cert_valid_days}" \
    -keysize "${keystore_keysize}" \
    -dname "${distinguished_names_node_str}"

  # Export certificates from key stores as a 'Signing Request' which the Root CA can then sign.
  keytool \
    -certreq \
    -alias "${node_alias}" \
    -file "${sign_req_cert_path}" \
    -keystore "${node_keystore_path}" \
    -storepass "${keystore_password}" \
    -keypass "${keystore_password}"

  # Sign each of the certificates using the Root CA.
  openssl x509 \
    -req \
    -CA "${root_ca_pc_path}" \
    -CAkey "${root_ca_psk_path}" \
    -in "${sign_req_cert_path}" \
    -out "${signed_cert_path}" \
    -days "${cert_valid_days}" \
    -CAcreateserial \
    -passin pass:${root_ca_psk_password}

  # Import the the Root CA into the key stores.
  keytool \
    -import \
    -alias "${root_ca_alias}" \
    -file "${root_ca_pc_path}" \
    -keystore "${node_keystore_path}" \
    -storepass "${keystore_password}" \
    -keypass "${keystore_password}"  \
    -noprompt

  # Import the signed certificates back into the key stores so that there is a complete chain.
  keytool \
    -import \
    -alias "${node_alias}" \
    -file "${signed_cert_path}" \
    -keystore "${node_keystore_path}" \
    -storepass "${keystore_password}" \
    -keypass "${keystore_password}"

  # Create the truststore and import the certificate. Note, if it already exists keytool will only import the certificate.
  if [ "${add_ca_to_truststore}" = "true" ]
  then
    keytool \
      -importcert \
      -alias "${root_ca_alias}" \
      -file "${root_ca_pc_path}" \
      -keystore "${truststore_path}" \
      -storepass "${truststore_password}" \
      -keypass "${root_ca_psk_password}" \
      -noprompt

    # Add the root certificate to an existing truststore if specified. This is useful when performing key rotation without
    # downtime.
    if [ -n "${existing_truststore_path}" ]
    then
      keytool \
        -importcert \
        -alias "${root_ca_alias}" \
        -file "${root_ca_pc_path}" \
        -keystore "${existing_truststore_path}" \
        -storepass "${EXISTING_TRUSTSTORE_PASSWORD}" \
        -keypass "${root_ca_psk_password}" \
        -noprompt
    fi

    # Perform the keytool operations for the truststore only once if our Certificate Authority is signing all the
    # certificates for the nodes in the cluster.
    if [ "${root_ca_creation_scope}" = "cluster" ]
    then
      add_ca_to_truststore="false"
    fi
  fi
done

if [ -f ".srl" ]
then
  mv ".srl" "${stores_dir}/.srl"
fi

echo "${truststore_name}:${truststore_password}" >> "${stores_password_file}"
