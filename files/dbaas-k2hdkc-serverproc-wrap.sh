#!/bin/sh
#
# K2HDKC DBaaS Helm Chart
#
# Copyright 2022 Yahoo Japan Corporation.
#
# K2HDKC DBaaS is a DataBase as a Service provided by Yahoo! JAPAN
# which is built K2HR3 as a backend and provides services in
# cooperation with Kubernetes.
# The Override configuration for K2HDKC DBaaS serves to connect the
# components that make up the K2HDKC DBaaS. K2HDKC, K2HR3, CHMPX,
# and K2HASH are components provided as AntPickax.
#
# For the full copyright and license information, please view
# the license file that was distributed with this source code.
#
# AUTHOR:   Takeshi Nakatani
# CREATE:   Fri Jan 21 2021
# REVISION:
#

#----------------------------------------------------------
# Common variables
#----------------------------------------------------------
PRGNAME=$(basename "$0")
SCRIPTDIR=$(dirname "$0")
SCRIPTDIR=$(cd "${SCRIPTDIR}" || exit 1; pwd)

ANTPICKAX_ETC_DIR="/etc/antpickax"
ANTPICKAX_RUN_DIR="/var/run/antpickax"

WATCHER_SERVICEIN_FILE="k2hkdc_servicein.cmd"
WATCHER_SERVICEIN_FILE_PATH="${ANTPICKAX_RUN_DIR}/${WATCHER_SERVICEIN_FILE}"
WATCHER_RECOVER_FILE="k2hkdc_recover.cmd"
WATCHER_RECOVER_FILE_PATH="${ANTPICKAX_RUN_DIR}/${WATCHER_RECOVER_FILE}"
WATCHER_STSUPDATE_FILE="k2hkdc_statusupdate.cmd"
WATCHER_STSUPDATE_FILE_PATH="${ANTPICKAX_RUN_DIR}/${WATCHER_STSUPDATE_FILE}"

WATCHER_OPT="-watcher"
RETRYCOUNT=60
FILE_RETRYCOUNT=60
SLEEP_LONG=20
SLEEP_MIDDLE=10
SLEEP_SHORT=1

#----------------------------------------------------------
# Make configuration file path
#----------------------------------------------------------
K2HR3_FILE_RESOURCE="k2hr3-resource"
if [ -f "${ANTPICKAX_ETC_DIR}/${K2HR3_FILE_RESOURCE}" ]; then
	K2HR3_YRN_RESOURCE=$(tr -d '\n' < "${ANTPICKAX_ETC_DIR}/${K2HR3_FILE_RESOURCE}" 2>/dev/null)
	K2HDDKC_MODE=$(echo "${K2HR3_YRN_RESOURCE}" | sed 's#[:/]# #g' | awk '{print $NF}')
else
	#
	# Always k2hdkc process is on server node, if not specified mode.
	#
	K2HDDKC_MODE="server"
fi
INI_FILE="${K2HDDKC_MODE}.ini"
INI_FILE_PATH="${ANTPICKAX_ETC_DIR}/${INI_FILE}"

#----------------------------------------------------------
# Wait configuration file creation
#----------------------------------------------------------
FILE_EXISTS=0
while [ "${FILE_EXISTS}" -eq 0 ]; do
	if [ -f "${INI_FILE_PATH}" ]; then
		FILE_EXISTS=1
	else
		FILE_RETRYCOUNT=$((FILE_RETRYCOUNT - 1))
		if [ "${FILE_RETRYCOUNT}" -le 0 ]; then
			echo "[ERROR] ${INI_FILE_PATH} is not existed."
			exit 1
		fi
		sleep "${SLEEP_SHORT}"
	fi
done

#----------------------------------------------------------
# Main processing
#----------------------------------------------------------
if [ -n "$1" ] && [ "$1" = "${WATCHER_OPT}" ]; then
	#
	# Run watcher
	#
	LOCALHOSTNAME=$(chmpxstatus -conf "${INI_FILE_PATH}" -self	| grep 'hostname'		| sed -e 's/[[:space:]]*$//g' -e 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*//g')
	CTLPORT=$(chmpxstatus -conf "${INI_FILE_PATH}" -self		| grep 'control port'	| sed -e 's/[[:space:]]*$//g' -e 's/^[[:space:]]*control port[[:space:]]*=[[:space:]]*//g')
	CUK=$(chmpxstatus -conf "${INI_FILE_PATH}" -self			| grep 'cuk'			| sed -e 's/[[:space:]]*$//g' -e 's/^[[:space:]]*cuk[[:space:]]*=[[:space:]]*//g')
	CUSTOM_SEED=$(chmpxstatus -conf "${INI_FILE_PATH}" -self	| grep 'custom id seed'	| sed -e 's/[[:space:]]*$//g' -e 's/^[[:space:]]*custom id seed[[:space:]]*=[[:space:]]*//g')

	{
		echo "servicein ${LOCALHOSTNAME}:${CTLPORT}:${CUK}:${CUSTOM_SEED}:"
		echo "sleep ${SLEEP_SHORT}"
		echo "statusupdate"
		echo "exit"
	} > "${WATCHER_SERVICEIN_FILE_PATH}"
	{
		echo "serviceout ${LOCALHOSTNAME}:${CTLPORT}:${CUK}:${CUSTOM_SEED}:"
		echo "sleep ${SLEEP_SHORT}"
		echo "statusupdate"
		echo "exit"
	} > "${WATCHER_RECOVER_FILE_PATH}"
	{
		echo "statusupdate"
		echo "exit"
	} > ${WATCHER_STSUPDATE_FILE_PATH}

	LOOP_BREAK=0
	while [ "${LOOP_BREAK}" -eq 0 ]; do
		if chmpxstatus -conf "${INI_FILE_PATH}" -self -wait -live up -ring servicein -nosuspend -timeout "${SLEEP_SHORT}" >/dev/null 2>&1; then
			if chmpxstatus -conf "${INI_FILE_PATH}" -self | grep 'status[[:space:]]*=' | grep '\[ADD\]' | grep '\[Pending\]' >/dev/null 2>&1; then
				# 
				# When the status is "ADD:Pending", type a new ServiceIn command after short sleep.
				#
				sleep ${SLEEP_MIDDLE}
				if chmpxstatus -conf "${INI_FILE_PATH}" -self | grep 'status[[:space:]]*=' | grep '\[ADD\]' | grep '\[Pending\]' >/dev/null 2>&1; then
					#
					# To Service Out
					#
					chmpxlinetool -conf "${INI_FILE_PATH}" -run "${WATCHER_RECOVER_FILE_PATH}" >/dev/null 2>&1
				fi
				sleep "${SLEEP_MIDDLE}"
			else
				sleep "${SLEEP_LONG}"
				chmpxlinetool -conf "${INI_FILE_PATH}" -run "${WATCHER_STSUPDATE_FILE_PATH}" >/dev/null 2>&1
			fi
		else
			if chmpxstatus -conf "${INI_FILE_PATH}" -self -wait -live up -ring serviceout -nosuspend -timeout "${SLEEP_SHORT}" >/dev/null 2>&1; then
				# 
				# When the status is "ServiceOut:NoSuspend", type a new ServiceIn command after short sleep.
				#
				sleep "${SLEEP_MIDDLE}"
				if chmpxstatus -conf "${INI_FILE_PATH}" -self -wait -live up -ring serviceout -nosuspend -timeout "${SLEEP_SHORT}" >/dev/null 2>&1; then
					#
					# To Service In
					#
					chmpxlinetool -conf "${INI_FILE_PATH}" -run "${WATCHER_SERVICEIN_FILE_PATH}" >/dev/null 2>&1
				else
					chmpxlinetool -conf "${INI_FILE_PATH}" -run "${WATCHER_STSUPDATE_FILE_PATH}" >/dev/null 2>&1
				fi
			fi
			sleep "${SLEEP_MIDDLE}"
		fi
	done

else
	#
	# Run k2hdkc
	#
	CHMPX_UP=0
	while [ "${CHMPX_UP}" -eq 0 ]; do
		#
		# Check keep status while SLEEP_LONG second
		#
		STATUS_KEEP_TIME="${SLEEP_LONG}"
		while [ "${STATUS_KEEP_TIME}" -gt 0 ]; do
			if ! chmpxstatus -conf "${INI_FILE_PATH}" -self -wait -live up -ring serviceout -suspend -timeout "${SLEEP_SHORT}" >/dev/null 2>&1; then
				if ! chmpxstatus -conf "${INI_FILE_PATH}" -self -wait -live up -ring servicein -suspend -timeout "${SLEEP_SHORT}" >/dev/null 2>&1; then
					break;
				fi
			fi
			sleep "${SLEEP_SHORT}"
			STATUS_KEEP_TIME=$((STATUS_KEEP_TIME - SLEEP_SHORT))
		done

		if [ "${STATUS_KEEP_TIME}" -le 0 ]; then
			CHMPX_UP=1
		else
			sleep "${SLEEP_MIDDLE}"
			RETRYCOUNT=$((RETRYCOUNT - 1))
			if [ "${RETRYCOUNT}" -le 0 ]; then
				break;
			fi
		fi
	done

	if [ "${CHMPX_UP}" -eq 0 ]; then
		exit 1
	fi

	#
	# Check and Create directory
	#
	K2HFILE=$(grep K2HFILE "${INI_FILE_PATH}" | sed -e 's/=//g' -e 's/K2HFILE//g' -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
	K2HDIR=$(dirname "${K2HFILE}")
	mkdir -p "${K2HDIR}"

	#
	# Run
	#
	if [ -n "${K2HDKC_MANUAL_START}" ] && [ "${K2HDKC_MANUAL_START}" = "true" ]; then
		tail -f /dev/null
	else
		#
		# Run checker process
		#
		/bin/sh "${SCRIPTDIR}/${PRGNAME}" "${WATCHER_OPT}" >/dev/null 2>&1 <&- &

		set -e

		#
		# stdio/stderr is not redirected.
		#
		k2hdkc -conf "${INI_FILE_PATH}" -d err
	fi
fi

exit $?

#
# Local variables:
# tab-width: 4
# c-basic-offset: 4
# End:
# vim600: noexpandtab sw=4 ts=4 fdm=marker
# vim<600: noexpandtab sw=4 ts=4
#
