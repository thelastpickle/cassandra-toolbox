#!/bin/bash

set -e

VERSION=2.0

version() {
  echo
  echo "$0 script version \"${VERSION}\""
  exit 0
}

usage() {
  cat << EOF

This script transfers snaphots in the data directory of the local Cassandra node to the data directory of a remote
Cassandra node via rsync. Only user defined (non-system) tables will be transferred by this script.

This script will transfer the snapshot SSTable files to the parent data directory on the remote host first and in
addition transfer a move script. The move script will check for any SSTable generation number conflicts before moving
the files. If a conflict is found, the generation number of the transferred file is multiplied by 10 prior to being
moved into its corresponding keyspace and table directory.

usage: $0 [OPTIONS] <LOCAL_DATA_DIRECTORY> <SNAPSHOT_TAG> <REMOTE_USER_NAME> <REMOTE_HOST_IP> <REMOTE_HOST_DATA_DIRECTORY>

arguments:
  LOCAL_DATA_DIRECTORY        Parent data directory as defined by the value of the data_file_directories setting in
                              the cassandra.yaml file on the local Cassandra node.

  SNAPSHOT_TAG                Tag name of the data snapshot to copy to remote host.

  REMOTE_USER_NAME            User name used when accessing the remote host via SSH.

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

  -y                    Answer Yes to all prompts.

  -v                    Display version information.

  -h                    Display usage.
EOF
  exit $1
}

create_remote_move_script() {
  remote_temp_path=$1
  remote_host_data_dir=$2

  cat << EOF > ./${sstabel_mv_script}
for data_db in \$(find $remote_temp_path -iname "*-Data.db" -type f | rev | cut -d'/' -f1 | rev)
do
  keyspace_name=\$(cut -d'-' -f1 <<< \${data_db})
  table_name=\$(cut -d'-' -f2 <<< \${data_db})
  src_gen_num=\$(cut -d'-' -f4 <<< \${data_db})
  dst_gen_num=\${src_gen_num}
  remote_data_path=$remote_host_data_dir/\$keyspace_name/\$table_name

  if [ -f "\${remote_data_path}/\${data_db}" ]
  then
    dst_gen_num=\$((\${src_gen_num} * 10))
  fi

  for sstable_file in \$(find $remote_temp_path -iname "\$keyspace_name-\$table_name-jb-\${src_gen_num}-*.*" -type f)
  do
    sstable_file_type=\$(cut -d'-' -f5 <<< \${sstable_file})
    mv -v \${sstable_file} \${remote_data_path}/\$keyspace_name-\$table_name-jb-\${dst_gen_num}-\${sstable_file_type}
  done
done
EOF

  chmod 755 ${sstabel_mv_script}
}


### Main code ###

sstabel_mv_script=sstable_mv.sh

# Always exclude system keyspaces as they will mess up a node that is already in the cluster.
exclude_list=(
  system
  system_traces
  system_auth
)
include_list=()
bandwidth_limit=""
skip_prompts="false"

while getopts "e:i:b:yvh" opt_flag
do
  case $opt_flag in
    e)
      exclude_list+=($OPTARG)
    ;;
    i)
      include_list+=($OPTARG)
    ;;
    b)
      bandwidth_limit="--bwlimit $OPTARG"
    ;;
    y)
      skip_prompts="true"
    ;;
    v)
      version
    ;;
    h)
      usage 0
    ;;
  esac
done

shift $(($OPTIND - 1))

if [ $# -lt 5 ]
then
  echo "Insufficient number of arguments."
  echo
  usage 1
fi

positional_arguments=(
  local_data_dir
  snapshot_tag
  remote_user_name
  remote_host_ip
  remote_host_data_dir
)

for arg_v in ${positional_arguments[@]}
do
  eval ${arg_v}=$1

  if [ -z "${!arg_v}" ]
  then
    echo "The positional argument $(tr '[:lower:]' '[:upper:]' <<< "${arg_v}") is undefined."
    echo
    usage 1
  fi

  shift
done

echo "Using arguments"
echo "  LOCAL_DATA_DIRECTORY:       ${local_data_dir}"
echo "  SNAPSHOT_TAG:               ${snapshot_tag}"
echo "  REMOTE_USER_NAME:           ${remote_user_name}"
echo "  REMOTE_HOST_IP:             ${remote_host_ip}"
echo "  REMOTE_HOST_DATA_DIRECTORY: ${remote_host_data_dir}"
echo


# General steps
#
# Find snashot tag (using LOCAL_DATA_DIRECTORY and SNAPSHOT_TAG)
# Filter out any tables
# Loop over resultant list
#   - Derive keyspace and table name from path
#   - Derive full destination path (using REMOTE_HOST_DATA_DIRECTORY)
#   - Make temp directory on remote host
#   - rsync snapshots to temp directory on remote host
#   - Move files in remote temp directory to remote data directory and check for generation number

find_dirs=""
if [ ${#include_list[@]} -gt 0 ]
then
  for ks_table in ${include_list[@]}
  do
    find_dirs="${find_dirs} ${local_data_dir}/$(tr -s '.' '/' <<< ${ks_table})"
  done
else
  # Search top level data directory for all tables.
  find_dirs="${local_data_dir}"
fi

grep_filter=""
for ks_table in ${exclude_list[@]}
do
  grep_filter="${grep_filter} | grep -v $(tr -s '.' '/' <<< ${ks_table})"
done

snapshot_list=($(eval "find ${find_dirs} -iname \"${snapshot_tag}\" -type d ${grep_filter}"))

echo "I will copy the following tables in snapshot tag ${snapshot_tag} from the local host to '${remote_host_data_dir}' on remote host ${remote_host_ip}."
echo ${snapshot_list[@]} | tr -s ' ' '\n'
echo

if [ ${skip_prompts} = "false" ]
then
  while [ 1 ]
  do
    read -p "Is it ok to proceed with the transfer [Y/n]? " yn
    case $yn in
      [Y]*)
        break
        ;;
      [Nn]*)
        exit 0
        ;;
      *)
        echo "Please answer [Y]es or [n]o."
        ;;
    esac
  done
fi

echo "OK. Starting snapshot transfer operations."

remote_temp_path="${remote_host_data_dir}/${snapshot_tag}_tmp"
ssh ${remote_user_name}@${remote_host_ip} "mkdir -p ${remote_temp_path}"

create_remote_move_script ${remote_temp_path} ${remote_host_data_dir}
rsync -azPog ${bandwidth_limit} ${sstabel_mv_script} ${remote_user_name}@${remote_host_ip}:${remote_host_data_dir}/

for snapshot_path in ${snapshot_list[@]}
do
  # Do the copy from the local to remote node
  rsync -azPog ${bandwidth_limit} ${snapshot_path}/ ${remote_user_name}@${remote_host_ip}:${remote_temp_path}/

  # Move file from temp location to keyspace/table directory
  ssh -t ${remote_user_name}@${remote_host_ip} "${remote_host_data_dir}/${sstabel_mv_script}"
done

if [ ${skip_prompts} = "false" ]
then
  while [ 1 ]
  do
    read -p "Delete ${remote_temp_path} directory and ${sstabel_mv_script} on remote host ${remote_host_ip} [Y/n]? " yn
    case $yn in
      [Y]*)
        break
        ;;
      [Nn]*)
        exit 0
        ;;
      *)
        echo "Please answer [Y]es or [n]o."
        ;;
    esac
  done
fi

ssh -t ${remote_user_name}@${remote_host_ip} "rm ${remote_host_data_dir}/${sstabel_mv_script} && rmdir ${remote_temp_path}"
