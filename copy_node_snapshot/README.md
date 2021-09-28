# Copy Node Snapshot

This script transfers snaphots in the data directory of the local Cassandra node to the data directory of a remote
Cassandra node via rsync. Only user defined (non-system) tables will be transferred by this script.

By default, this script will transfer the snapshot SSTable files to the parent data directory on the remote host first
and in addition transfer a move script. The move script will check for any SSTable generation number conflicts before
moving the files. If a conflict is found, the generation number of the transferred file is multiplied by 10 prior to
being moved into its corresponding keyspace and table directory.

The default transfer behaviour can be overridden, so that rsync transfers the snapshot directly into the data directory
of the remote host. In this mode any conflicting SSTables are overridden by the incoming snapshot.

```
usage: copy_node_snapshot.sh [OPTIONS] <LOCAL_DATA_DIRECTORY> <SNAPSHOT_TAG> <REMOTE_USER_NAME> <REMOTE_HOST_IP> <REMOTE_HOST_DATA_DIRECTORY>

arguments:
LOCAL_DATA_DIRECTORY        Parent data directory as defined by the value of the data_file_directories setting in
                            the cassandra.yaml file on the local Cassandra node.

SNAPSHOT_TAG                Tag name of the data snapshot to copy to remote host.

REMOTE_USER_NAME            Username used when accessing the remote host via SSH.

REMOTE_HOST_IP              IP Address of the remote host to copy the snapshot data to.

REMOTE_HOST_DATA_DIRECTORY  Parent data directory as defined by the value of the data_file_directories setting in
                            the cassandra.yaml file on the remote Cassandra node.

options:
-e=KEYSPACE[.TABLE]   A user defined keyspace (non-system keyspace) or table name to exclude in the copy. This option
                      can be specified multiple times.
                      If this option is used by itself, all user defined tables will be part of the snapshot
                      transfer except the tables and tables in keyspaces defined by this option.
                      If this option is used with the '-i' option, only those tables and tables in the keyspaces
                      defined by the '-i' option will be initially considered for the snapshot transfer. The tables
                      and tables in keyspaces defined by this option will be excluded. The table name must include
                      the keyspace name separated by a dot. For example:
                          foo_ks.bar_table


-i=KEYSPACE[.TABLE]   A user defined keyspace (non-system keyspace) or table name to include in the copy. This option
                      can be specified multiple times.
                      If this option is used by itself, no tables will be part of the snapshot transfer except for
                      the tables and tables in keyspaces defined by this option.
                      If this option is used with the '-e' option, the tables and tables in keyspaces defined by the
                      option will be excluded from the snapshot transfer.  The table name must include the keyspace
                      name separated by a dot. For example:
                          foo_ks.bar_table

-b=KB_SEC             Maximum bandwidth in kilobytes per second to use for file transfer. This value could be the
                      value of the stream_throughput_outbound_megabits_per_sec setting in the cassandra.yaml file.
                      Note that there is a unit difference here. The Cassandra setting is in Mega Bits per Second
                      where as the rsync option is in Kilo Bytes per Second. Hence, we will need to take the
                      stream_throughput_outbound_megabits_per_sec value, divide it by 8 and then multiply it by
                      1,000 to convert it to the value to use.

-d                    Directly transfer the snapshot into the data directory of the remote host. In this mode any
                      conflicting SSTables are overridden by the incoming snapshot. This mode is useful for remote
                      hosts that are offline.

-y                    Answer Yes to all prompts.

-v                    Display version information.

-h                    Display usage.
```