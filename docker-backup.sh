#!/bin/bash

# Sleep until the given time of the day (today or the next day)
sleep_until() {
	local now next slp
	now=$(date +%s)
	next=$(date +%s --date "$1")
	if [ $now -ge $next ] ; then
		slp=$(($next-$now+86400))
	else
		slp=$(($next-$now))
	fi
	printf 'sleep %ss, -> %(%c)T\n' $slp $((now+slp))
	sleep $slp
}

# Check the connection to the host and ensure the repository is created
function check_repository {
	# First check the repository
	echo "[INFO] First checking the repository"
	restic check &> restic_check.log
	return_value=$?

	# If it is locked, wait and check again
	sleep_time=10
	while grep -q "repository is already locked by" restic_check.log ; do
		echo "[INFO] Repository locked, waiting ... and trying to unlock before trying to check again"
		sleep $(($sleep_time + $RANDOM % 60))
		sleep_time=$(($sleep_time * 2))
		restic unlock
		restic check &> restic_check.log
		return_value=$?
	done

	# If it does not exist, create it (and ignore any other kind of error)
	if grep -q -E 'Is there a repository at the following location|file does not exist' restic_check.log ; then
		# Wait a random amount of time to make sure two nodes will not try to do it at the same time
		echo "[INFO] Repository not found, waiting a bit before trying to create it ..."
		sleep $(($RANDOM % 300))

		# Check again to make sure it has not been initialised while waiting
		restic check &> restic_check.log
		return_value=$?
		if grep -q -E 'Is there a repository at the following location|file does not exist' restic_check.log ; then
			# Then manually create it
			echo "[INFO] ... It's time, creating it"
			restic init &> restic_check.log
			return_value=$?
		else
			echo "[INFO] ... Repository has been created while waiting so I have nothing to do"
		fi
	fi

	cat restic_check.log
	return $return_value
}

# Backup one directory using Restic
function backup_dir {
	# Check if the dir to backup is mounted as a subdirectory of /root inside this container
	if [ -d "/root_fs$1" ] ; then
		while true ; do
			restic --host $2 backup /root_fs$1 &> restic_check.log
			if [ $? -ne 0 ]; then
				if grep -q "repository is already locked by" restic_check.log ; then
					echo "[INFO] Repository locked, waiting ... and trying to unlock before trying to backup again"
					sleep $(($RANDOM % 600))
					restic unlock
					continue
				else
					echo "[ERROR] Unable to create repository"
					cat restic_check.log
					return $?
				fi
			else
				cat restic_check.log
				return 0
			fi
		done
	else
		echo "[ERROR] Directory $1 not found. Have you mounted the root fs from your host with the following option : '-v /:/root_fs:ro' ?"
		return -1
	fi
}

# Backup one file using Restic
function backup_file {
	while true ; do
		cat $1 | restic backup --host $3 --stdin --stdin-filename $2 &> restic_check.log
		if [ $? -ne 0 ]; then
			if grep -q "repository is already locked by" restic_check.log ; then
				echo "[INFO] Repository locked, waiting ... and trying to unlock before trying to backup again"
				sleep $(($RANDOM % 600))
				restic unlock
				continue
			else
				echo "[ERROR] Unable to create repository"
				cat restic_check.log
				return $?
			fi
		else
			cat restic_check.log
			return 0
		fi
	done
}

function control_container {
	curl -s --unix-socket /var/run/docker.sock -X POST http:/v1.41/containers/$1/$2
	echo "[INFO] "$2"(p)ing container" $1
}

# Find all the directories to backup and call backup_dir for each one
function run_backup {
	count_success=0
	count_failure=0

	# List all the containers
	containers=$(curl -s --unix-socket /var/run/docker.sock http:/v1.26/containers/json)
	for container_id in $(echo $containers | jq ".[].Id") ; do
		container=$(echo $containers | jq -c ".[] | select(.Id==$container_id)")

		# Get the name and namespace (in case of a container run in a swarm stack)
		container_name=$(echo $container | jq -r ".Names | .[0]" | cut -d'.' -f1 | cut -d'/' -f2)
		namespace=$(echo $container | jq -r ".Labels | .[\"com.docker.stack.namespace\"]")

		# Backup the dirs labelled with "napnap75.backup.dirs"
		if $(echo $container | jq ".Labels | has(\"napnap75.backup.dirs\")") ; then
			for dir_name in $(echo $container | jq -r ".Labels | .[\"napnap75.backup.dirs\"]") ; do
				if $(echo $container | jq ".Labels | has(\"napnap75.backup.stopstart\")") ; then
					control_container $container_name stop
				else
					echo "[INFO] Not stopping container"
				fi
				echo "[INFO] Backing up dir" $dir_name "for container" $container_name
				backup_dir $dir_name $1
				if [ $? -ne 0 ]; then
					((++count_failure))
				else
					((++count_success))
				fi
				control_container $container_name start
			done
		fi

		# Backup the databases labelled with "napnap75.backup.databases"
		if $(echo $container | jq ".Labels | has(\"napnap75.backup.databases\")") ; then
			container_id=$(echo $container_id | sed "s/\"//g")
			database_password=$(curl -s --unix-socket /var/run/docker.sock http:/v1.26/containers/$container_id/json | jq -r ".Config.Env[] | match(\"MYSQL_ROOT_PASSWORD=(.*)\") | .captures[0].string")
			for database_name in $(echo $container | jq -r ".Labels | .[\"napnap75.backup.databases\"]") ; do
				echo "[INFO] Backing up database" $database_name "for container" $container_name
				if [[ "$database_password" != "" ]] ; then
					exec_id=$(curl -s --unix-socket /var/run/docker.sock -X POST -H "Content-Type: application/json" -d '{"AttachStdout":true,"AttachStderr":true,"Tty":true,"Cmd":["/bin/bash", "-c", "mysqldump -p'$database_password' --databases '$database_name'"]}' http:/v1.26/containers/$container_id/exec | jq ".Id" | sed "s/\"//g")
				else
					exec_id=$(curl -s --unix-socket /var/run/docker.sock -X POST -H "Content-Type: application/json" -d '{"AttachStdout":true,"AttachStderr":true,"Tty":true,"Cmd":["/bin/bash", "-c", "mysqldump --databases '$database_name'"]}' http:/v1.26/containers/$container_id/exec | jq ".Id" | sed "s/\"//g")
				fi
				curl -s --unix-socket /var/run/docker.sock -X POST -H "Content-Type: application/json" -d '{"Detach":false,"Tty":false}' http:/v1.26/exec/$exec_id/start | gzip > /tmp/database_backup.gz
				exit_code=$(curl -s --unix-socket /var/run/docker.sock http:/v1.26/exec/$exec_id/json | jq ".ExitCode")
				if [ $exit_code -ne 0 ]; then
					echo "[ERROR] Unable to backup database $database_name from container $container_name"
					cat /tmp/database_backup.gz | gzip -d
					((++count_failure))
				else
					backup_file /tmp/database_backup.gz ${container_name}—${database_name}.sql.gz $1
					if [ $? -ne 0 ]; then
						((++count_failure))
					else
						((++count_success))
					fi
				fi
				rm /tmp/database_backup.gz
			done
		fi
	done

	if [[ "$SLACK_URL" != "" ]] ; then
		curl -s -X POST --data-urlencode "payload={\"username\": \"rpi-docker-backup\", \"icon_emoji\": \":dvd:\", \"text\": \"Backup finished on host $HOSTNAME : $count_success succeeded, $count_failure failed\"}" $SLACK_URL
	fi
	if [[ "$INFLUXDB_URL" != "" ]] ; then
		curl -s -X POST --data-binary "backups,host=$HOSTNAME success=$count_success,failure=$count_failure" $INFLUXDB_URL
	fi

	echo "Remove old snapshots"
	restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 75 --prune
}

# Set the hostname to the node name when used with Docker Swarm
NODE_NAME=$(curl -s --unix-socket /var/run/docker.sock http:/v1.26/info | jq -r ".Name")
if [[ "$NODE_NAME" != "" ]] ; then
	echo "[INFO] Swarm mode detected, using node name $NODE_NAME instead of $HOSTNAME as hostname"
	HOSTNAME="$NODE_NAME"
fi

# When used with SFTP set the SSH configuration file
if [[ "$RESTIC_REPOSITORY" = sftp:* ]] ; then
	# Copy the key and make it readable only by the current user to meet SSH security requirements
	cp $SFTP_KEY /tmp/foreign_host_key
	chmod 400 /tmp/foreign_host_key
	SFTP_KEY=/tmp/foreign_host_key

	# Initialize the SSH config file with the values provided in the environment
	mkdir -p /root/.ssh
	echo "Host $SFTP_HOST" > /root/.ssh/config
	if [[ "$SFTP_PORT" != "" ]] ; then echo "Port $SFTP_PORT" >> /root/.ssh/config ; fi
	echo "IdentityFile $SFTP_KEY" >> /root/.ssh/config
	echo "StrictHostKeyChecking no" >> /root/.ssh/config
fi

# First check the connection and the repository
check_ok=0
if [[ "$NO_CHECK" != "true" ]] ; then
	check_repository
	check_ok=$?
fi

# Run the script if everything was fine
if [ $check_ok == 0 ] ; then
	if [ "$1" == "run-once" ] ; then
		# Run only once, mainly for tests purpose
		echo "[INFO] Starting backup immediatly"
		run_backup $HOSTNAME
	else
		# Run everyday at $start_time
		start_time=$(($RANDOM % 7)):$(($RANDOM % 60))
		echo "[INFO] Backup will start at $start_time every day"
		while true ; do
			sleep_until $start_time
			run_backup $HOSTNAME
		done
	fi
else
	echo "[ERROR] Unable to check the connection and the repository (error code $check_ok)"
	if [[ "$SLACK_URL" != "" ]] ; then
		curl -s -X POST --data-urlencode "payload={\"username\": \"rpi-docker-backup\", \"icon_emoji\": \":dvd:\", \"text\": \"Unable to connect to repository $RESTIC_REPOSITORY while trying to run the backup on host $HOSTNAME\"}" $SLACK_URL
	fi
	if [[ "$INFLUXDB_URL" != "" ]] ; then
		curl -s -X POST --data-binary "backups,host=$HOSTNAME error_code=$check_ok" $INFLUXDB_URL
	fi
	exit 1
fi
