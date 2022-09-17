#!/bin/bash

set -e

VERSION=3.0

version() {
  echo
  echo "$0 script version \"${VERSION}\""
  exit 0
}

usage() {
  cat << EOF

This script transfers snaphots in the data directory of the local Cassandra node to the data directory of a remote
Cassandra node via rsync. Only user defined (non-system) tables will be transferred by this script.

By default, this script will transfer the snapshot SSTable files to the parent data directory on the remote host first
and in addition transfer a move script. The move script will check for any SSTable generation number conflicts before
moving the files. If a conflict is found, the generation number of the transferred file is multiplied by 10 prior to
being moved into its corresponding keyspace and table directory.

The default transfer behaviour can be overridden, so that rsync transfers the snapshot directly into the data directory
of the remote host. In this mode any conflicting SSTables are overridden by the incoming snapshot.

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

  -d                    Directly transfer the snapshot into the data directory of the remote host. In this mode any
                        conflicting SSTables are overwritten by the incoming snapshot. This mode is useful for remote
                        hosts that are offline.

  -o                    Overwrite any conflicting SSTables with the incoming snapshot when using the default transfer
                        method (i.e. indirect). This option is ignored when the -d option is used, because a direct
                        transfer will have the same behaviour for conflicting SSTables.

  -y                    Answer Yes to all prompts.

  -v                    Display version information.

  -h                    Display usage.
EOF
  exit $1
}

create_remote_move_script() {
  remote_temp_path=$1
  remote_host_data_dir=$2
  sstabe_conflict_mode=$3

  cat << EOF > ./${sstabel_mv_script}
#!/bin/bash

keyspace_name=\$1
table_name=\$2
remote_data_path=\$(find $remote_host_data_dir/\${keyspace_name} -iname "\${table_name}*" -type d)

for data_db in \$(find $remote_temp_path -iname "*-Data.db" -type f | rev | cut -d'/' -f1 | rev)
do
  sstable_file_prefix=\$(sed -r "s/(.*)\-Data.db/\1/g" <<<"\${data_db}")
  gen_multiplier=""

  if [ -f "\${remote_data_path}/\${data_db}" ] && [ "$sstabe_conflict_mode" = "preserve" ]
  then
    gen_multiplier="0"
  fi

  for sstable_file in \$(find $remote_temp_path -iname "\${sstable_file_prefix}-*.*" -type f)
  do
    sstable_file_src=\$(rev <<<\${sstable_file} | cut -d'/' -f1 | rev)
    sstable_file_dst=\$(sed -r "s/([j-n][a-e])\-([0-9]*)\-/\1-\2\${gen_multiplier}-/g" <<<\${sstable_file_src})
    mv -v $remote_temp_path/\${sstable_file_src} \${remote_data_path}/\${sstable_file_dst}
  done
done
EOF

  chmod 755 "${sstabel_mv_script}"
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
transfer_mode="indirect"
sstable_conflict="preserve"

while getopts "e:i:b:doyvh" opt_flag
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
    d)
      transfer_mode="direct"
    ;;
    o)
      sstable_conflict="overwrite"
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
    *)
      usage 1
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

for arg_v in ${positional_arguments[*]}
do
  eval "${arg_v}"="$1"

  if [ -z "${!arg_v}" ]
  then
    echo "The positional argument $(tr '[:lower:]' '[:upper:]' <<< "${arg_v}") is undefined."
    echo
    usage 1
  fi

  shift
done

cat << EOF
Using arguments
  LOCAL_DATA_DIRECTORY:       $local_data_dir
  SNAPSHOT_TAG:               $snapshot_tag
  REMOTE_USER_NAME:           $remote_user_name
  REMOTE_HOST_IP:             $remote_host_ip
  REMOTE_HOST_DATA_DIRECTORY: $remote_host_data_dir
EOF

# General steps
#
# Find snashot tag (using LOCAL_DATA_DIRECTORY and SNAPSHOT_TAG)
# Filter out any tables
# Loop over resultant list
#   - Derive keyspace and table name from path
#   - Derive full destination path (using REMOTE_HOST_DATA_DIRECTORY)
#   If running in "indirect" transfer mode
#   - Make temp directory on remote host
#   - rsync snapshots to temp directory on remote host
#   - Move files in remote temp directory to remote data directory and check for generation number conflicts
#   If running in "direct" transfer mode
#   - rsync snapshots to remote data directory

find_dirs=""
if [ ${#include_list[@]} -gt 0 ]
then
  for ks_table in ${include_list[*]}
  do
    keyspace_name=$(cut -d'.' -f1 <<< "${ks_table}")
    table_name=$(cut -s -d'.' -f2 <<< "${ks_table}")

    if [ -n "${table_name}" ]
    then
      for actual_table_name in $(find "${local_data_dir}/${keyspace_name}" -iname "${table_name}*" -type d | \
        grep -v snapshots | \
        rev | \
        cut -d'/' -f1 | \
        rev)
      do
        find_dirs="${find_dirs} ${local_data_dir}/${keyspace_name}/${actual_table_name}"
      done
    else
      find_dirs="${find_dirs} ${local_data_dir}/${keyspace_name}"
    fi
  done
else
  # Search top level data directory for all tables.
  find_dirs="${local_data_dir}"
fi

grep_filter=""
for ks_table in ${exclude_list[*]}
do
  grep_filter="${grep_filter} | grep -v $(tr -s '.' '/' <<< "${ks_table}")"
done

snapshot_list=($(eval "find ${find_dirs} -iname \"${snapshot_tag}\" -type d ${grep_filter}"))

echo "I will copy the following tables in snapshot tag ${snapshot_tag} from the local host to '${remote_host_data_dir}' on remote host ${remote_host_ip} using ${transfer_mode} transfer method."
echo "${snapshot_list[*]}" | tr -s ' ' '\n'
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

remote_dest_path=""
rsync_options=""

if [ "${transfer_mode}" = "indirect" ]
then
  # -a - Archive mode which includes recursion and permission preservation.
  # -z - Compress file data during the transfer.
  # -P - Keep partially transferred file and show progress
  rsync_options="-azP"
  remote_dest_path="${remote_host_data_dir}/${snapshot_tag}_tmp"

  # Create temp directory on the remote host, create remote move script, and push the move script to the remote host.
  ssh "${remote_user_name}@${remote_host_ip}" "mkdir -p ${remote_dest_path}"
  create_remote_move_script "${remote_dest_path}" "${remote_host_data_dir}" "${sstable_conflict}"
  rsync ${rsync_options} ${bandwidth_limit} ${sstabel_mv_script} ${remote_user_name}@${remote_host_ip}:${remote_host_data_dir}/
elif [ "${transfer_mode}" = "direct" ]
then
  # --delete-before - Removes any existing file in the destination folder that is not present in the source folder.
  rsync_options="-azP --delete-before"
fi

for snapshot_path in ${snapshot_list[*]}
do
  # Get keyspace and table so we can find the table directory on the remote host.
  keyspace_name=$(rev <<< "${snapshot_path}" | cut -d'/' -f4 | rev)
  table_name=$(rev <<< "${snapshot_path}" | cut -d'/' -f3  | rev | cut -d'-' -f1)

  if [ "${transfer_mode}" = "direct" ]
  then
    echo "Contacting ${remote_host_ip} to find the directory for table ${keyspace_name}.${table_name}"
    remote_dest_path=$(ssh -t "${remote_user_name}@${remote_host_ip}" "find ${remote_host_data_dir}/${keyspace_name} -iname \"${table_name}*\" -type d" | tr -d '\r')
    # --delete-before - Removes any existing file in the destination folder that is not present in the source folder.
    rsync_options="-azP --delete-before"
  fi

  # Do the copy from the local to remote node
  echo "Starting transfer of files in ${snapshot_path} to remote ${remote_host_ip}:${remote_dest_path}"
  rsync ${rsync_options} ${bandwidth_limit} ${snapshot_path}/ ${remote_user_name}@${remote_host_ip}:${remote_dest_path}/

  if [ "${transfer_mode}" = "indirect" ]
  then
    # Run the move script on the remote host to move the data from temp location to keyspace/table directory
    echo "Moving files on ${remote_host_ip} from ${remote_dest_path} to ${remote_host_data_dir}"
    ssh -t "${remote_user_name}@${remote_host_ip}" "${remote_host_data_dir}/${sstabel_mv_script} ${keyspace_name} ${table_name}"
  fi
done

if [ "${transfer_mode}" = "indirect" ]
then
  if [ ${skip_prompts} = "false" ]
  then
    while [ 1 ]
    do
      read -p "Delete ${remote_dest_path} directory and ${sstabel_mv_script} on remote host ${remote_host_ip} [Y/n]? " yn
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

  rm ${sstabel_mv_script}
  ssh -t "${remote_user_name}@${remote_host_ip}" "rm ${remote_host_data_dir}/${sstabel_mv_script} && rmdir ${remote_dest_path}"
fi