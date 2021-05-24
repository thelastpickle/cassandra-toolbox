# Generate Cluster SSL Stores

This script generates the Keystores and Truststore to use when SSL encrypting communications between Cassandra nodes.

The script will iterate through a node list (if supplied) and generate a root certificate for each node. Each
certificate is self-signed and inserted into a keystore. Each root certificate is added to a common truststore. If no
node list is supplied a single keystore and truststore are generated.

```
Usage: generate_cluster_ssl_stores.sh [OPTIONS] <CA_CERT_CONFIG_PATH>

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
```