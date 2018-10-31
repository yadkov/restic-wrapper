#!/usr/bin/env bash
# Created by Georgi Yadkov
# OS: Centos 7
# usage: restic-wrapper.sh /path/to/dir /path/to/config/file.conf site-address
# 
# variables:
# $1 - directory for backup
# $2 - config file
# $3 - name of the archive which to be included in the log name
#
# The following variables are provided in the config file
# * restic repo path
# * restic repo password
# * AWS access key
# * AWS secret key
#
# Changelog
# [0.2] - for the next release
# * help implemented
# * debug function
# * restic retention period as a variable
# * parameter checking
# * dbdump - function extension with clean parameter
# * dbdump - provide parameters
# * provide restic and aws binaries as variables
# * create systemd timer
# * include site SSL certificates
#
# [0.1] - 2018-10-25
# * backup directory is provided by $1 variable in the script 


# exit on error
set -o errexit
set -o pipefail
set -o nounset


## Variables
scriptversion="0.1"
scriptname=$(basename "$0")
timestamp=$(date +"%F %T")
backupdir="$1"
resticbackupdirandfiles=("${backupdir}")
log=/var/log/restic-"$3".log

# source the config file
resticconfig="$2"
source "${resticconfig}"

## Functions
restic-config-vars() {
	# Function checks for config file of MOODLE, Mautic, OSTicket, Singularity
	# Redmine and extract variables for db and additional directories
	# to be included or excluded in the backup.

	backuptype=""
	local moodleconfigfile="${backupdir}/config.php"
	local osticketconfigfile="${backupdir}/include/ost-config.php"
	local mauticconfigfile="${backupdir}/app/config/local.php"
	local redmineconfigfile="${backupdir}/config/database.yml"

	if test -e "${moodleconfigfile}" 
	then 
		backuptype="MOODLE"
	elif test -e "${osticketconfigfile}"
	then
		backuptype="OSTICKET"
	elif test -e "${mauticconfigfile}"
	then
		backuptype="MAUTIC"
	elif test -e "${redmineconfigfile}"
	then
		backuptype="REDMINE"
	else
		backuptype=""
	fi


	case "${backuptype}" in
		MOODLE)
			moodledataroot="$(awk -F\' '/CFG->dataroot/ { print $2 }' "${moodleconfigfile}")"
			resticbackupdirandfiles+=("${moodledataroot}")
			dbname="$(awk -F\' '/CFG->dbname/ { print $2 }' "${moodleconfigfile}")"
			dbuser="$(awk -F\' '/CFG->dbuser/ { print $2 }' "${moodleconfigfile}")"
			dbpass="$(awk -F\' '/CFG->dbpass/ { print $2 }' "${moodleconfigfile}")"
			resticexclude=()
			resticexclude+=("${moodledataroot}/cache")
			resticexclude+=("${moodledataroot}/localcache")
			resticexclude+=("${moodledataroot}/lock")
			resticexclude+=("${moodledataroot}/sessions")
			resticexclude+=("${moodledataroot}/temp")
			resticexclude+=("${moodledataroot}/trashdir")
			;;
		OSTICKET)
			dbname="$(awk -F\' '/DBNAME/ { print $4 }' "${osticketconfigfile}")"
			dbuser="$(awk -F\' '/DBUSER/ { print $4 }' "${osticketconfigfile}")"
			dbpass="$(awk -F\' '/DBPASS/ { print $4 }' "${osticketconfigfile}")"
			;;
		REDMINE)
			dbname=$(grep "${redmineconfigfile}" -e "^production" -A 6 | awk '/database/ { print $2 }')
			dbuser=$(grep "${redmineconfigfile}" -e "^production" -A 6 | awk '/username/ { print $2 }')
			dbpass=$(grep "${redmineconfigfile}" -e "^production" -A 6 | awk -F\" '/password/ { print $2 }')
			;;
		MAUTIC)
			dbname="$(awk -F\' '/db_name/ { print $4 }' "${mauticconfigfile}")"
			dbuser="$(awk -F\' '/db_user/ { print $4 }' "${mauticconfigfile}")"
			dbpass="$(awk -F\' '/db_pass/ { print $4 }' "${mauticconfigfile}")"
			resticexclude=()
			resticexclude+=("${backupdir}/app/cache")
			;;
		*)
	esac
}

dbdump() {
	echo "${timestamp} Starting dbdump procedure."

	# set the dump location directory and dumpfile name
	dbdumplocation="/tmp/${dbname}"
	dbdumpfile="${dbdumplocation}/${dbname}.sql"

	# if needed create dump directory
	if [ ! -d "${dbdumplocation}" ]
	then
		mkdir --parents "${dbdumplocation}" 
	else
		# or delete the content in the dump direcory
		rm -rf "${dbdumplocation:?}"/*
	fi

	# dumping the database 
	/usr/bin/mysqldump \
		--user="${dbuser}" \
		--password="${dbpass}" \
		"${dbname}" > "${dbdumpfile}"

}

calculateAWSBucketSize() {
	# calculate the size of the bucket where the repo is hold
	# the bucket name is taken from the restic repository
	# TODO check if AWS is available
	#
	# Variables:
	# $AWSBucket - $1 parameter

	local AWSBucket="$1"

	echo "$(date +"%F %T") \
	$(echo "$(/home/backup/.local/lib/aws/bin/aws s3api list-objects \
	--bucket "${AWSBucket}" \
	--output json \
	--query "[sum(Contents[].Size)]" \
	 | jq '.[0]') / 1024^3" \
	 | bc)G" used for the AWS restic repo.
}

resticOperations() {
	# Creating the snapshot in the repo with restic, deleting unused
	# snapshots and checking the integrity of the archive.
	#
	# TODO check for the restic location
	#
	# Variables:
	# $resticexclude - array with files/dirs to be excluded from the backup
	# $resticbackupdirandfiles - array with files/dirs to be include in the backup

	echo $(date +"%F %T")" Taking snapshot in restic"

	# check if array resticexclude has elements
	# taken from https://unix.stackexchange.com/questions/56837/how-to-test-if-a-variable-is-defined-at-all-in-bash-prior-to-version-4-2-with-th
	case " ${!resticexclude*} " in
	  *" resticexclude "*)
		"${HOME}/.local/bin/restic" backup $(echo ${resticbackupdirandfiles[*]}) \
			"${resticexclude[@]/#/--exclude=}" --quiet
					;;
	  *) 
		"${HOME}/.local/bin/restic" backup $(echo ${resticbackupdirandfiles[*]}) --quiet
					;;
	esac

	echo $(date +"%F %T")" Cleaning old snapshots"
	# TODO make it as a variable
	"${HOME}/.local/bin/restic" forget \
		--keep-daily 7 \
		--keep-weekly 5 \
		--keep-monthly 12 \
		--prune

	echo $(date +"%F %T")" Checking restic repo integrity"
	"${HOME}/.local/bin/restic" check
}

# the main event
main() {

	echo '======================================='
	echo $(date +"%F %T")" Start backup procedure"
	echo "Script: ${scriptname}" 
	echo "Version: ${scriptversion}"
	echo "Configuration file: ${resticconfig}"

	restic-config-vars

	# database dumping if applicable
	if test -z "${dbname-}" || test -z "${dbuser-}" || test -z "${dbpass-}" 
	then
		echo $(date +"%F %T")" No db dump is required."
		dbdumpfile=""
	else
		dbdump
		# include the dump file into the restic snapshot
		resticbackupdirandfiles+=("${dbdumpfile}")
	fi
	
	resticOperations

	calculateAWSBucketSize "${RESTIC_REPOSITORY##*/}"

	# clean dbdump
	rm "${dbdumpfile}"

	echo $(date +"%F %T")" End backup procedure"
}

# start
main 2>&1 | tee -a "${log}"
