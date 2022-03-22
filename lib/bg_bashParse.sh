#!/bin/bash

# Library
# analyze bash scripts depedencies

# usage: bparse_build [<project>]
# parse the scripts for vinstalled projects to build a cyjs data file for visualizing the graph of project, file and function
# dependencies
# Params:
#    <project> : limit to only scripts in this project instead of all installed scripts
function bparse_build()
{
	local project="$1"; shift
	gawk '@include "bg_bashParse.awk"' < <(bparse_raw "$@")
}


# usage: bparse_raw
# print the raw bash parse output for all scripts in the sandbox
# Params:
#    <project> : limit to only scripts in this project instead of all installed scripts
function bparse_raw()
{
	local project="$1"; shift
	while read -r pkgName assetType assetName filePath; do
		printf "\n[AssetInfo] $pkgName $assetType $assetName $filePath\n"
		cat "$filePath"
		printf "?!?"  # insert a tokan which can not be valid bash so that the awk script can detect the start of the parser output
		bashParse --parse-tree-print "$filePath" || assertError
	done < <(
		manifestGet  ${project:+--pkg=$project} ".*bash" ".*"
	)
}
