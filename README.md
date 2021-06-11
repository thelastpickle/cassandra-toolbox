# Cassandra Toolbox

A collection of tools useful for maintaining Apache Cassandra

## [Copy Node Snapshot](copy_node_snapshot)
This script transfers snaphots in the data directory of the local Cassandra node to the data directory of a remote
Cassandra node via rsync.

## [Generate Cluster SSL Stores](generate_cluster_ssl_stores)
This script generates the Keystores and Truststore for a cluster to use when SSL encrypting communications between
Cassandra nodes.