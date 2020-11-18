#!/bin/bash

#import bg_spProfile.sh ;$L1;$L2
import bg_dev.sh ;$L1;$L2
import bg_cui.sh ;$L1;$L2

# CRITICALTODO: sync the bg-sp profile project template file changes

# Library
# library to extract documentation from source code.
# This library contains functions that mange the generation of documentation from the source code in a project. It initially recognizes
# bash script source but will work on other source languages without too much modification.
#
# The are two main parts to this library. First is the source scanner which is offloaded to the awk script of the same name. That
# script can be fed one or more source files at a time.
#
# The second main part is the algorithm that writes the current set of manpages to a temp folder and then processes differences
# to change only what is needed in the project's funcman folder. There are support functions that maintain that folder. At one time
# the standard was to commit the generated folder to git but to use git hooks to hide changes until special funcman commits so that
# the funman changes would not overwhelm the real changes and make the history hard to track. Currently I am not committing the funcman
# folder because the parsing is so much faster that its not a problem to generate them in each sandbox.
#
# Command Manpages:
# template = funcman.1.bashCmd
# Each bash script provided by the project will have a man(1) page creates. If the script contains a comment block starting with
# "# Command " its content will be added to the manpage.
#
# Library Manpages:
# template = funcman.7.bashLibrary
# Each bash library script (ending in .sh) in the project will get a man(7) page created. Its synopsis section will contain a list
# of functions contained in the library.
#
# If a comment section exists in the global scope of the library file that starts with "# Library " that comment block will
# become the description section.
#
# Bash Function Manpages:
# template = funcman.3.bashFunction
# Each bash function in library script files that do not start with an underscore will get a man(3) page created.
# The comment block before the function declaration will be parsed and becomes the description section.
# Functions that start with an underscore are, by convention, private to the library and will not have a manpage created by default.
# To make a manpage be created for a private function, you can start the function's comment block with "# man(3) "
#
# Other Manpages:
# Any global scope comment block in a library file that starts with the following line will produce a manpage in the specified
# section with the specified name
#         # man(<section>) <pageName>
# Templates:
# Templates reside in the bg-sp-profile folder associated with the project under the templates/ folder. If there is no bg-sp-profile
# folder, the default templates are found in this project's data folder (/usr/share/bg-dev/templates). Templates are named like
# funcman.<manSection>.<type>
#
# You can support new types of manpages by adding a template with a new <type> and adding a comment block starting with
# "# man(<manSection>.<type>)"
#
# See Also:
#    man(1) bg-dev-funcman

#################################################################################################################################
### FUNCMAN Functions

# usage: funcman_listTemplates
# print the names of the known template files to stdout
function funcman_listTemplates()
{
	local verbosity="${verbosity:-1}" templateFolder
	while [ $# -gt 0 ]; do case $1 in
		-t*|--templateFolder*) bgOptionGetOpt val: templateFolder "$@" && shift ;;
		-q|--quiet)            ((verbosity--)) ;;
		-v|--verbose)          ((verbosity++)) ;;
		--verbosity*)          bgOptionGetOpt val: verbosity "$@" && shift ;;
		 *)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	# get the template folder and man3 creation template
	if [ ! "$templateFolder" ]; then
		#templateFolder="$(profileGetFolder)/templates"
		[ ! -d "$templateFolder" ] && templateFolder="$pkgDataFolder/templates"
	fi
	[ ! -d "$templateFolder" ] && assertError -v templateFolder "template folder not folder. can not proceed without templates"

	echo "templateFolder='$templateFolder'"
	bgfind -B "$templateFolder"/funcman. "$templateFolder" -name "funcman*"
}

# usage: local listInGit listInWorkTree listNew listRemoved listIntersection; _funcman_getStatusLists
# this fills in 5 variables declared in the callers scope to represent the difference between controled and uncontrolled funcman pages
function _funcman_getStatusLists()
{
	assertInPkgProject

	# man3/ has never had human maintained manpages but the other sections might have non funcman pages
	# funcman pages in any section except 3 will end in sh
	listInGit="$(git  ls-files -c "man*/*sh" "man3/*")"
	listInWorkTree="$(ls -1 man*/*sh man3/* 2>/dev/null)"
	listNew="$(         strSetSubtract -d " " "$listInWorkTree"  "$listInGit")"
	listRemoved="$(     strSetSubtract -d " " "$listInGit"       "$listInWorkTree")"
	listIntersection="$(strSetSubtract -d " " "$listInGit"       "$listRemoved")"
}


# usage: funcman_reset
# throw away changes made to the generated man pages so that there is nothing to commit
# this can be useful if there are no changes except to generated man pages and you do not want to commit them.
function funcman_reset()
{
	assertInPkgProject

	local listInGit listInWorkTree listNew listRemoved listIntersection
	_funcman_getStatusLists

	[ "$listInGit" ] && git checkout $listInGit
	[ "$listNew" ] && rm $listNew
}

# usage: funcman_gitUnhide
# configure git so that changes to the generated funcman pages will be seen as available to commit
function funcman_gitUnhide()
{
	assertInPkgProject

	local listInGit listInWorkTree listNew listRemoved listIntersection
	_funcman_getStatusLists

	# turn the ignore bit off on any man3/* files
	git update-index --no-assume-unchanged $listInGit

	local gitFolder="$(git rev-parse --resolve-git-dir .git)"
	configLineReplace -d "$gitFolder/info/exclude" "man*/*sh"
	configLineReplace -d "$gitFolder/info/exclude" "man3/*"
}

# usage: funcman_gitHide
# configure git so that changes to the generated funcman pages will not be seen
# this allows the author to concentrate on real content changes
function funcman_gitHide()
{
	assertInPkgProject

	local listInGit listInWorkTree listNew listRemoved listIntersection
	_funcman_getStatusLists

	# turn the ignore bit off on any man3/* files
	git update-index --assume-unchanged $listInGit

	local gitFolder="$(git rev-parse --resolve-git-dir .git)"
	configLineReplace  "$gitFolder/info/exclude" "man*/*sh"
	configLineReplace  "$gitFolder/info/exclude" "man3/*"
}

# usage: funcman_gitCommit [-f|--force]
# commit any changes to the generated funcman pages to git
# Options:
#    -f|--force : force the commit to happen even if there are other staged content that will be included in
#                 the commit. Typically we want funcman commits to be separate so that they do not obscure the
#                 real content changes
function funcman_gitCommit()
{
	local forceFlag
	while [ $# -gt 0 ]; do case $1 in
		-f|--force) forceFlag="-f" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	assertInPkgProject

	# unless -f is specified, refuse to make a funcman commit if there are non funcman changes staged that we be included
	# by default we want funcman commits that only contain funcman changes
	if [ ! "$forceFlag" ] && [ "$(git diff --name-only --cached | grep -v "^man3/" | grep -v "^man[0-9]/.*sh")" ]; then
		assertError "can not create a funcman commit becuase there are other staged changes in the index that will go into the next commit. Either make a real commit first or unstage that content"
	fi

	local listInGit listInWorkTree listNew listRemoved listIntersection
	_funcman_getStatusLists

	# unhide the changes so that we can commit them
	funcman_gitUnhide

	# this takes care of any modified files that are already in git and also new files
	# the -f is needed so that it adds new files listed on the cmd line that  match an .gitignore pattern
	# even though gitUnhide removes the info/exclude gitignore patterns, projects can have a real man3/*
	# .gitignore pattern for legacy reasons.
	# -A does not work well because it will also remove files that are outside man3/*
	[ "$listNew$listIntersection" ] && git add -f  $listNew $listIntersection

	# we tell it to remove files explicitly. Git is changing its behavior regarding whether git add will mark
	# a file listed on the cmd line that does not exist in the work tree as being deleted so we stay away
	# from that for now and use rm directly
	[ "$listRemoved" ] && git rm $listRemoved >/dev/null

	# if any changes were recorded, make a funcman commit
	if [ "$(git diff --name-only --cached | grep  "^man[0-9]/")" ]; then
		# commit. if the last commit is a funcman and not yet pushed, amend it instead of making multiple ones
		local currentBranch="$(git branch 2>/dev/null|grep "^*" | tr -d "* ")"
		local commitsAvialToPush=$( { git rev-list origin/$currentBranch..$currentBranch 2>/dev/null || echo "countThisAsOne"; } | wc -l)
		if [ ${commitsAvialToPush:-1} -gt 0 ] && [ "$(git show -s --pretty=format:"%s" HEAD)" == "funcman" ]; then
			(export EDITOR=touch; git commit --amend &>/dev/null)
		else
			git commit -m"funcman" &>/dev/null
		fi
	fi

	# hide the changes again so that only real changes will be visible even after the funcman pages start to change
	funcman_gitHide
}


function setTemplateContextVars()
{
	# export all the variables set in .bg-sp/config. We also make sure some values are set even if they are missing from config.
	assertFileExists .bg-sp/config
	while IFS='=' read -r name value; do
		export $name="$value"
	done <.bg-sp/config
	export packageName="${packageName:-${PWD##*/}}"
	export pkgName="$packageName"
	export projectName="${projectName:-$packageName}"

	# time/date values for use in templates
	export timeStamp="$(date +"%Y-%m-%d:%H:%M:%S")"
	export year=$(date +"%Y")
	export month=$(date +"%B")
	export fullDate=$(date +"%c")
	export date_rfc_2822=$(date -R)

	# user's full, display name for use in templates
	export fullUsername
	fullUsername=$(iniParamGet /etc/bg-sp.conf "profile:$profileName" "fullUsername")
	fullUsername="${fullUsername:-$(getIniParam /etc/bg-sp.conf "DefaultUserInfo" "fullUsername")}"
	which  git>/dev/null && fullUsername="${fullUsername:-$(git config --get user.name 2>/dev/null)}"
	fullUsername="${fullUsername:-$(getent passwd $USER | cut -d: -f 5 | cut -d, -f1)}"

	# user's email for use in templates
	export userEmail
	userEmail=$(getIniParam /etc/bg-sp.conf "profile:$profileName" "userEmail")
	userEmail="${userEmail:-$(getIniParam /etc/bg-sp.conf "DefaultUserInfo" "userEmail")}"
	which  git>/dev/null && userEmail="${userEmail:-$(git config --get user.email 2>/dev/null)}"
	[ "$companyDomain" ] && userEmail="${userEmail:-$USER@$companyDomain}"
	userEmail="${userEmail:-$USER@$(cat /etc/mailname 2>/dev/null || hostname --all-fqdns)}"
}


# usage: funcman_testRun [-v|-q] <sourceFileSpec>
# Run the funcman scanner on one or more files printing diagnostic information to stdout instead of generating the manpages.
# This is typically used to confirm that the scanner is interpretting the source correctly to create the intended manpages.
# higher verbosity levels show more information
function funcman_testRun()
{
	local verbosity="${verbosity:-1}" templateFolder renderFlag openInManFlag outputFolder
	while [ $# -gt 0 ]; do case $1 in
		-t*|--templateFolder*) bgOptionGetOpt val: templateFolder "$@" && shift ;;
		-o*|--outputFolder*)   bgOptionGetOpt val: outputFolder   "$@" && shift ;;
		--render)              renderFlag="all" ;;
		-m|--man)              openInManFlag="-m" ;;
		-q|--quiet)            ((verbosity--)) ;;
		-v|--verbose)          ((verbosity++)) ;;
		--verbosity*)          bgOptionGetOpt val: verbosity "$@" && shift ;;
		 *)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local sourceFileSpec="$1"; assertNotEmpty sourceFileSpec
	[ "$2" ] && renderFlag="$2"

	# get the template folder and man3 creation template
	if [ ! "$templateFolder" ]; then
		#templateFolder="$(profileGetFolder)/templates"
		[ ! -d "$templateFolder" ] && templateFolder="$(bgGetDataFolder bg-dev)/templates"
	fi
	[ ! -d "$templateFolder" ] && assertError -v templateFolder "template folder not folder. can not proceed without templates"
	local templateFuncmanBase="$templateFolder/funcman"
	[ ! -f "$templateFuncmanBase".1.bashCmd ] && assertError -v templateFolder -v templateFuncmanBase "template for funcman Functions (.1.bashCmd) is not found in the profile's template folder"
	[ ! -f "$templateFuncmanBase".3.bashFunction ] && assertError -v templateFolder -v templateFuncmanBase "template for funcman Functions (.3.bashFunction) is not found in the profile's template folder"
	[ ! -f "$templateFuncmanBase".7.bashLibrary ]  && assertError -v templateFolder -v templateFuncmanBase "template for funcman Functions (.7.bashLibrary) is not found in the profile's template folder"
	[ ${verbosity:-1} -ge 2 ] && printfVars "   " -w14 templateFuncmanBase

	local tmpFolder; [ "$openInManFlag" ] && bgmktemp -d tmpFolder
	awk \
		-v renderFlag="$renderFlag" \
		-v verbosity="$verbosity" \
		-v tmpFolder="$tmpFolder" \
		-v outputFolder="$outputFolder" \
		-v commonIncludesStr="$commonIncludes" \
		-v templateFuncmanBase="$templateFuncmanBase" \
	'
		@include "bg_funcman.awk"
	' $(fsExpandFiles -f $sourceFileSpec)

	if [ "$openInManFlag" ]; then
		man "$tmpFolder"/* 2>/dev/null
		ls -1 "$tmpFolder"/
		bgmktemp --release tmpFolder
	fi
}

# usage: funcman_runBatch [-t <templateFolder>] [-o <outputFolder>] [--dry-run] [-q] [-I <inptFileArray>] <sourceFileSpec>
# this reads bash script source files and produces a man page for each eligible functions and man
# page comment section found. funcman stands for function manpage but it does more than functions now. It also generates pages
# libraries, any man(?) page, and soon for commands.
# It uses templates in the bg-sp-profile project that the package project was created under.
# This function assumes that its being run in a bg-bg_spPkgProject project and updates the known man folders in such a way to
# minimize trivial changes.
# It uses an awk script bg_funcman.awk to do the actual scanning and that script could be invoked directly if you want to use it
# outside a bg_spPkgProject.
# Params:
#   <sourceFileSpec> : the source files that will be scanned for eligible functions
# Options:
#   -i|--inputFiles=<arrayVar> : an alternative to <sourceFileSpec> to specify the input files.
#   -t <templateFolder> : the folder where the required templates are found. The default is to use
#          $(profileGetFolder)/templates to get the environment's current profile folder and if that
#          fails to use the package data folder $dataFolder/templates
#   -o <outputFolder> : the folder to write the function manpages to. Existing files in this folder are inteligently
#          updated so that their timestamps will not be changed if the logical content does not change.
#          when new content is updated, the creation time in the existing manpage is preserved.
#   -q|--quiet   : print less information about what is changing
#   -v|--verbose : print more information about what is changing
#   --dry-run : do not change the output folder but only report on what changes would be done. option to open new content in IDE
#   --compare : do not change the output folder but open a compare app to see the differences and allow user to cherry pick changes
function funcman_runBatch()
{
	local templateFolder outputFolder dryRunFlag verbosity=1 filesVar
	while [ $# -gt 0 ]; do case $1 in
		-i*|--inputFiles)      bgOptionGetOpt val: filesVar "$@" && shift ;;
		-t*|--templateFolder*) bgOptionGetOpt val: templateFolder "$@" && shift ;;
		-o*|--outputFolder*)   bgOptionGetOpt val: outputFolder   "$@" && shift ;;
		-q|--quiet)            ((verbosity--)) ;;
		-v|--verbose)          ((verbosity++)) ;;
		--verbosity*)          bgOptionGetOpt val: verbosity "$@" && shift ;;
		--dry-run)             dryRunFlag="--dry-run" ;;
		--compare)             dryRunFlag="--compare" ;;
		 *)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local sourceFileSpec="$*"

	# I think eventually, the funcman scanner will produce the ctags file -- at least for bash scripts. In the meantime, use etags
	funcman_ctagsBuild

	if [ ! "$filesVar" ]; then
		local _files=()
		filesVar="files"
	fi
	local getAllFilesVar="$filesVar[@]"

	# init  filesVar to the expanded sourceFileSpec (if provided, typically this is empty)
	fsExpandFiles -A "$filesVar" $sourceFileSpec

	# if no sourceFileSpec, then do the whole project
	if [ $(arraySize "$filesVar") -eq 0 ]; then
		local project type file
		while read -r project type file; do
			case $type in
			  globalBashCompletion) arrayPush "$filesVar" "$file" ;;
			  bashLib) arrayPush "$filesVar" "$file" ;;
			  cmd) [[ $(file "$file") =~ Bourne-Again ]] && arrayPush "$filesVar" "$file" ;;
			esac
		done < $(fsExpandFiles .bglocal/manifest)
	fi

	# set the environment with the project attributes and some global attributes for the template expansion to use.
	setTemplateContextVars

	# get the template folder and man3 creation template
	if [ ! "$templateFolder" ]; then
		#templateFolder="$(profileGetFolder)/templates"
		[ ! -d "$templateFolder" ] && templateFolder="$pkgDataFolder/templates"
	fi
	[ ! -d "$templateFolder" ] && assertError -v templateFolder "template folder not folder. can not proceed without templates"
	local templateFuncmanBase="$templateFolder/funcman"
	[ ! -f "$templateFuncmanBase".1.bashCmd ] && assertError -v templateFolder -v templateFuncmanBase "template for funcman Functions (.1.bashCmd) is not found in the profile's template folder"
	[ ! -f "$templateFuncmanBase".3.bashFunction ] && assertError -v templateFolder -v templateFuncmanBase "template for funcman Functions (.3.bashFunction) is not found in the profile's template folder"
	[ ! -f "$templateFuncmanBase".7.bashLibrary ]  && assertError -v templateFolder -v templateFuncmanBase "template for funcman Functions (.7.bashLibrary) is not found in the profile's template folder"
	[ ${verbosity:-1} -ge 1 ] && printfVars "   " -w14 templateFuncmanBase

	# output folder processing
	outputFolder="${outputFolder:-.bglocal/funcman}"
	fsTouch -d "$outputFolder/"
	[ ${verbosity:-1} -ge 1 ] && printfVars "   " -w14 outputFolder

	# get the list of files sourced by bg_common.sh/bg_lib.sh so that we can show the right synopsis
	local commonIncludes="$(awk '/^[[:space:]]*import[[:space:]]/ {f=$2; gsub("[;].*$","",f); print f} ' $(fsExpandFiles -f "$(import --getPath bg_coreImport.sh)") | tr "\n" " ")"


	# this scans the input source files and outputs a man folder hierarchy to $tmpFolder/man<section>/<page>
	# outputFolder is passed in so that it can read the creation date from the previous verions so that it can stay consistent
	local tmpFolder; bgmktemp -d ${dryRunFlag:+-k} tmpFolder
	awk \
		-v verbosity="$((verbosity-1))" \
		-v tmpFolder="$tmpFolder" \
		-v outputFolder="$outputFolder" \
		-v commonIncludesStr="$commonIncludes" \
		-v templateFuncmanBase="$templateFuncmanBase" \
	'
		@include "bg_funcman.awk"
	' "${!getAllFilesVar}"

	# make a merged list of the union of manpage base filenames from the outputFolder
	# and tmpFolder. the -S option puts the results in the index of the associative
	# array so that dupes are removed. The -B makes it return only the basename part
	local -A allPages=()
	fsExpandFiles -F -S allPages -B "$outputFolder/" $outputFolder/man*/*
	fsExpandFiles -F -S allPages -B "$tmpFolder/"    $tmpFolder/man*/*

	# now sort the files into one of these four lists
	local newPages=() removedPages=() updatedPages=() blockedPages=() unchangedPages=()
	for manpage in "${!allPages[@]}"; do
		if [ ! -f "$outputFolder/$manpage" ]; then
			newPages+=("$manpage")
		elif [ ! -f "$tmpFolder/$manpage" ]; then
			# only remove pages that were created by funcman
			if [[ "$manpage" =~ ^man3/ ]] || grep -q "^[.][/]"'"'" FUNCMAN" "$outputFolder/$manpage" 2>/dev/null; then
				removedPages+=("$manpage")
			fi
		elif ! diff -q -wbB "$tmpFolder/$manpage" "$outputFolder/$manpage" &>/dev/null; then
			# only overwrite pages that were created by funcman
			if [[ "$manpage" =~ ^man3/ ]] || [ ! -s "$outputFolder/$manpage" ] || grep -q "^[.][/]"'"'" FUNCMAN" "$outputFolder/$manpage" 2>/dev/null; then
				updatedPages+=("$manpage")
			else
				blockedPages+=("$manpage")
			fi
		else
			unchangedPages+=("$manpage")
		fi
	done

	# this is a summary of how many were updated, removed, added, etc...
	if [ ${verbosity:-1} -ge 0 ]; then
		printfVars "   " -w14 "allPages:${#allPages[@]}"
		printfVars "   " -w14 "newPages:${#newPages[@]}"
		printfVars "   " -w14 "removedPages:${#removedPages[@]}"
		printfVars "   " -w14 "updatedPages:${#updatedPages[@]}"
		printfVars "   " -w14 "unchangedPages:${#unchangedPages[@]}"
		printfVars "   " -w14 "blockedPages:${#blockedPages[@]}"
	fi

	# new manpages
	for manpage in "${newPages[@]}"; do
		[ ${verbosity:-1} -ge 2 ] && echo "creating: $manpage"
		local outputFilename="$outputFolder/$manpage"
		local outputFoldername="${outputFilename%/*}"
		[ ! -e "$outputFoldername" ] && mkdir -p "$outputFoldername"
		# we want it to have normal permission bits, not /tmp folder bits so we cat
		#[ ! "$dryRunFlag" ] && aaaTouch -d "" -e "$outputFolder/$manpage"
		[ ! "$dryRunFlag" ] && cat "$tmpFolder/$manpage" > "$outputFilename"
	done

	# removed manpages
	for manpage in "${removedPages[@]}"; do
		[ ${verbosity:-1} -ge 2 ] && echo "removing: '$manpage'"
		[ ! "$dryRunFlag" ] && rm "$outputFolder/$manpage"
	done

	# updated manpages
	for manpage in "${updatedPages[@]}"; do
		[ ${verbosity:-1} -ge 2 ] && echo "updating: $manpage"
		# we want it to have normal permission bits, not /tmp folder bits so we cat
		[ ! "$dryRunFlag" ] && cat "$tmpFolder/$manpage" > "$outputFolder/$manpage"
	done

	if [ "$dryRunFlag" == "--dry-run" ] && confirm "launch file manager ($(getUserFileManagerApp)) on the tmp output folder?"; then
		$(getUserFileManagerApp -w)  "$tmpFolder"
		rm -rf "$tmpFolder"
	fi

	if [ "$dryRunFlag" == "--compare" ]; then
		$(getUserCmpApp) \
			--diff "$tmpFolder/" "$outputFolder/"
#			--diff "$tmpFolder/man5" "$outputFolder/man5" \
#			--diff "$tmpFolder/man7" "$outputFolder/man7"
		rm -rf "$tmpFolder"
	fi

	bgmktemp --release tmpFolder
}

function funcman_ctagsBuild() {
	if which ctags &>/dev/null; then
		ctags -R --extra=+f --exclude="*.bglocal/*" --exclude="*node_modules/*"
		sed -i -E '/^(if|switch|function|module\.exports|it|describe).+language:js$/d' tags
		[ ${verbosity} -ge 2 ] && echo "created tags file"
	else
		[ ${verbosity} -ge 1 ] && echo "no ctags command is installed. install 'apt install exuberant-ctags' to enable tags file generation"
	fi
}
