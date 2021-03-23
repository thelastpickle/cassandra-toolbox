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
EXISTING_TRUSTSTORE_PASSWORD - The password of an existing Truststore when using the -t option to
                                  populate the existing store with the new Certificate Authorities generated
                                  for the nodes.


Options:
 -g                             Generate passwords for each Keystore and Truststore. The passwords will be written to a
                                .password file along with the corresponding store name. If the TRUSTSTORE_PASSWORD
                                environment variable is set, this option will generate passwords for only each Keystore.

 -n=NODE_LIST                   Comma separated list of nodes defined by NODE_LIST to generate Certificate Authorities
                                and stores for. For example:
                                    127.0.0.1,127.0.0.2,127.0.0.3

                                If unspecified, a single Keystore and Truststore will be generated.

 -k=KEYSTORE_SUFFIX             String defined by KEYSTORE_SUFFIX that will be used to form the Keystore name. The
                                format of the name is <IP_ADDRESS><KEYSTORE_SUFFIX>.jks. Defaults to an empty string.

 -t=TRUSTSTORE_NAME             String defined by TRUSTSTORE_NAME that will be used to form the truststore name.
                                Defaults to 'cassandra-server-truststore'. In this case final file name will be
                                    cassandra-server-truststore.jks

 -s=KEYSTORE_KEY_SIZE           The size of the Keystore key defined by KEYSTORE_KEY_SIZE in bits. Defaults to 2048.

 -v=VALID_DAYS                  Number of days defined by VALID_DAYS the Root Certificate Authority ill be valid for.
                                Defaults to 365.

 -d=DISTINGUISHED_NAMES         String containing the X.500 Distinguished Names used to identify entities. When
                                supplying a distinguished name string, it must be quoted and in the following format:

                                    "CN=cName, OU=orgUnit, O=org, L=city, S=state, C=countryCode"

                                Where all the italicised items represent actual values and the above keywords are
                                abbreviations for the following:

                                    CN=Common Name
                                    OU=Organization Unit
                                    O=Organization Name
                                    L=Locality Name
                                    S=State Name
                                    C=Country

                                Further details about the Distinguished Names can be found in the Java documentation:

                                    https://docs.oracle.com/javase/8/docs/technotes/tools/unix/keytool.html#CHDHBFGJ

                                If the Distinguished Names are undefined, you will be prompted to specify their values.

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

generate_password() {
  openssl rand -base64 32 | tr -d '/' | tr -d '='
}


### Main code ###

time_stamp=$(date +"%Y%m%d_%H%M%S")
generate_passwords=false
node_list=""
keystore_suffix=""
truststore_name="cassandra-server-truststore"
keystore_keysize=2048
ca_valid_days=365
distinguished_names=""
existing_truststore_path=""
output_path="./ssl_artifacts_${time_stamp}"

while getopts "gn:k:t:s:v:d:e:o:h" opt_flag; do
  case $opt_flag in
    g)
      generate_passwords="true"
      ;;
    n)
      node_list=$OPTARG
      ;;
    k)
      keystore_suffix=$OPTARG
      ;;
    t)
      truststore_name=$OPTARG
      ;;
    s)
      keystore_keysize=$OPTARG
      ;;
    v)
      ca_valid_days=$OPTARG
      ;;
    d)
      distinguished_names=$OPTARG
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
  echo "Path to the existing Truststore ${existing_truststore_path} has been defined but no password set in environment variable CASSANDRA_EXISTING_TRUSTSTORE_PASSWORD"
  echo ""
  usage
fi

#
# Parse node list if supplied and push values into an array.
if [ -n "${node_list}" ]
then
  node_array=("$(tr -s ',' ' ' <<< "${node_list}")")
fi

#
# Use three separate stores:
#   - The Cassandra Keystore that will contain the Cassandra private certificate.
#   - The Generic Truststore that is will contain the Root CA used to sign the private certificates in the
#       Cassandra and Reaper Keystores.
#
certs_dir="${output_path}/certs"
stores_dir="${output_path}"

mkdir -p "${stores_dir}"
mkdir -p "${certs_dir}"

echo
echo "Artifacts generated will be placed in: '${output_path}'"

echo
echo "Using Certificate Authority configuration to generate keystores"
cat "${ca_cert_config_path}"

stores_password_file="${stores_dir}/stores.password"
truststore_password=""
truststore_path="${stores_dir}/${truststore_name}"

# Check if we need to add an extension to the truststore name
if [ "$(rev <<< "${truststore_name}" | cut -d'.' -f1 | rev)" != 'jks' ]
then
  truststore_path="${truststore_path}.jks"
fi

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

ca_key_password=$(grep output_password "${ca_cert_config_path}" | sed 's/[[:space:]]//g' | cut -d'=' -f2)

for node_i in ${node_array[*]}
do
  echo
  echo "Generate Keystore for node: ${node_i}"

  node_name=$(tr -s '.' '-' <<< "${node_i}")

  node_alias="${node_name}_${time_stamp}"

  root_ca_alias="${node_name}_CARoot_${time_stamp}"
  root_ca_cert="${certs_dir}/${node_name}_${time_stamp}_ca.cert"

  ca_key="${certs_dir}/${node_name}_${time_stamp}_ca.key"

  cert_sign_req="${certs_dir}/${node_name}_${time_stamp}_cert.sr"
  cert_signed="${certs_dir}/${node_name}_${time_stamp}_signed.cert"

  node_keystore_path="${stores_dir}/${node_name}${keystore_suffix}.jks"

  echo
  echo "  - Root CA alias:      ${root_ca_alias}"
  echo "  - Root CA cert path:  ${root_ca_cert}"
  echo "  - Key CA path:        ${ca_key}"
  echo "  - Keystore path:      ${node_keystore_path}"

  # Create the Root Certificate Authority (Root CA) from the Certificate Authority Configuration and verify contents.
  openssl req -config "${ca_cert_config_path}" -new -x509 -keyout "${ca_key}" -out "${root_ca_cert}" -days "${ca_valid_days}"
  openssl x509 -in "${root_ca_cert}" -text -noout

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

  echo "${node_name}${keystore_suffix}.jks:${keystore_password}" >> "${stores_password_file}"

  # Generate public/private key pair and the key stores.
  keytool \
    -genkeypair \
    -keyalg RSA \
    -alias "${node_alias}" \
    -keystore "${node_keystore_path}" \
    -storepass "${keystore_password}" \
    -keypass "${keystore_password}" \
    -keysize "${keystore_keysize}" \
    -dname "${distinguished_names}"

  # Export certificates from key stores as a 'Signing Request' which the Root CA can then sign.
  keytool \
    -certreq \
    -alias "${node_alias}" \
    -file "${cert_sign_req}" \
    -keystore "${node_keystore_path}" \
    -storepass "${keystore_password}" \
    -keypass "${keystore_password}"

  # Sign each of the certificates using the Root CA.
  openssl x509 \
    -req \
    -CA "${root_ca_cert}" \
    -CAkey "${ca_key}" \
    -in "${cert_sign_req}" \
    -out "${cert_signed}" \
    -CAcreateserial \
    -passin pass:${ca_key_password}

  # Import the the Root CA into the key stores.
  keytool \
    -import \
    -alias "${root_ca_alias}" \
    -file "${root_ca_cert}" \
    -keystore "${node_keystore_path}" \
    -storepass "${keystore_password}" \
    -keypass "${keystore_password}"  \
    -noprompt

  # Import the signed certificates back into the key stores so that there is a complete chain.
  keytool \
    -import \
    -alias "${node_alias}" \
    -file "${cert_signed}" \
    -keystore "${node_keystore_path}" \
    -storepass "${keystore_password}" \
    -keypass "${keystore_password}"

  # Create the truststore.
  keytool \
    -importcert \
    -alias "${root_ca_alias}" \
    -file "${root_ca_cert}" \
    -keystore "${truststore_path}" \
    -storepass "${truststore_password}" \
    -keypass "${ca_key_password}" \
    -noprompt

  # Add the root certificate to an existing truststore if specified. This is useful when performing key rotation without
  # downtime.
  if [ -n "${existing_truststore_path}" ]
  then
    keytool \
      -importcert \
      -alias "${root_ca_alias}" \
      -file "${root_ca_cert}" \
      -keystore "${existing_truststore_path}" \
      -storepass "${EXISTING_TRUSTSTORE_PASSWORD}" \
      -keypass "${ca_key_password}" \
      -noprompt
  fi
done

if [ -f ".srl" ]
then
  mv ".srl" "${stores_dir}/.srl"
fi

echo "${truststore_name}:${truststore_password}" >> "${stores_password_file}"
