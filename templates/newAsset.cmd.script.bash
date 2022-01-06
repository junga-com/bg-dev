#!/usr/bin/env bash

###############################################################################
# Includes and defines

packageName=%packageName%

source /usr/lib/bg_core.sh
#import <someLibrary.sh> ;$L1;$L2

###############################################################################
# Command manpage
# usage: %assetName% [<options>] <param1> ...
# <one line description...>
# <description...>
#
# Options:
# Params:
# See Also:


###############################################################################
# Functions

# this is invoked by oob_invokeOutOfBandSystem when -hb is the first param
# The bash completion script calls this get the list of possible words.
function oob_printBashCompletion()
{
	bgBCParse "<glean>" "$@"; set -- "${posWords[@]:1}"

	exit
}

# Use this function to provide BC suggestions for positional parameters
# see man bg-overviewOutOfBandScriptFunctions for details
function oob_helpMode()
{
	local -A clInput; bgCmdlineParse -RclInput "<glean>" "$@"; shift "${clInput[shiftCount]}"
	case ${clInput[cmd]:-main} in
		main)  man "$(basename $0)" ;;
		*)     man "$(basename $0)" ;;
	esac
}


###############################################################################
# Main script

# default values for parameters
verbosity=1
oob_invokeOutOfBandSystem "$@"
while [ $# -gt 0 ]; do case $1 in
	-v|--verbose) ((verbosity++)) ;;
	-q|--quiet) ((verbosity--)) ;;
	--verbosity*) bgOptionGetOpt val: verbosity "$@" && shift ;;
	*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
done
param1="$1"; shift
param2="$1"; shift

echo "TODO: create an awesome script... "
